#!/usr/bin/with-contenv bashio

# Load configuration variables from Home Assistant's add-on options
zoneId=$(bashio::config "zoneId")
apiToken=$(bashio::config "apiToken")
hostfqdn=$(bashio::config "hostfqdn")
v4Enabled=$(bashio::config "v4Enabled")
prefixLength=$(bashio::config "prefixLength")
refresh=$(bashio::config "refresh")
dnsttl=$(bashio::config "dnsttl")
proxied=$(bashio::config "proxied")
legacyMode=$(bashio::config "legacyMode")
customEnabled=$(bashio::config "customEnabled")
customRecords=$(bashio::config "customRecords")

# Convert refresh time from seconds to minutes
refreshMin=$((refresh / 60))
failCount=0  # Counter for failed attempts
successCount=0  # Counter for successful attempts
hextets=$((prefixLength / 16))  # Number of IPv6 hextets based on prefix length
v6new=
v4new=
v6=
v4=

# Function to make Cloudflare API requests (GET, POST, PUT)
cf_api() {
    method=$1  # HTTP method (GET, POST, PUT)
    endpoint=$2  # API endpoint
    data=${3:-}  # Data payload for POST/PUT requests (optional)

    # Perform the API call using curl and capture response
    curl -s -X "$method" "https://api.cloudflare.com/client/v4/zones/${zoneId}/${endpoint}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        ${data:+--data "$data"} 
}

# Function to manage DNS records (create or update)
cf_manage_record() {
    local fqdn=$1       # Fully qualified domain name (FQDN)
    local record_type=$2  # DNS record type (A or AAAA)
    local record_value=$3  # The value for the DNS record (IPv4 or IPv6)

    # Validate inputs
    if [[ -z "$fqdn" || -z "$record_type" || -z "$record_value" ]]; then
        printf "Error: Missing parameters for cf_manage_record: fqdn='%s', type='%s', value='%s'\n" \
            "$fqdn" "$record_type" "$record_value" >&2
        return 1
    fi

    # Check if the record exists
    local record_id
    record_id=$(cf_api GET "dns_records?type=${record_type}&name=${fqdn}" | grep -oE '"id":"[0-9a-fA-F]{32}"' | grep -oE '[0-9a-fA-F]{32}')

    # Create or update the record
    if [[ $record_id =~ ^[0-9a-fA-F]{32}$ ]]; then
        printf "\n\nUpdating record for %s (%s)\n" "$fqdn" "$record_type"
        cf_api PUT "dns_records/${record_id}" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}" || {
            printf "Error: Failed to update record for %s (%s)\n" "$fqdn" "$record_type" >&2
            return 1
        }
    else
        printf "\n\nCreating new record for %s (%s)\n" "$fqdn" "$record_type"
        cf_api POST "dns_records" "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}" || {
            printf "Error: Failed to create record for %s (%s)\n" "$fqdn" "$record_type" >&2
            return 1
        }
    fi
}

# Function to process custom DNS records
parse_records() {
    # Validate if customRecords is not empty
    if [[ -z "$customRecords" ]]; then
        printf "\n\nError: customRecords is empty or not set.\n" >&2
        return 1
    fi

    # Process each record in customRecords
    printf "%s\n" "$customRecords" | while IFS=, read -r record_fqdn record_type suffix; do
        # Skip empty or malformed lines
        if [[ -z "$record_fqdn" || -z "$record_type" ]]; then
            printf "\n\nWarning: Skipping invalid record entry: %s,%s,%s\n" "$record_fqdn" "$record_type" "$suffix" >&2
            continue
        fi

        # Validate record type
        if [[ "$record_type" != "A" && "$record_type" != "AAAA" ]]; then
            printf "\n\nWarning: Invalid record type '%s' for '%s'. Skipping.\n" "$record_type" "$record_fqdn" >&2
            continue
        fi

        # Determine the appropriate value (IPv4 or IPv6) for the record
        local record_value
        if [[ "$record_type" == "A" ]]; then
            record_value="$v4"  # Use IPv4 for "A" records
        elif [[ "$record_type" == "AAAA" ]]; then
            record_value="$v6"  # Default to IPv6
            [[ -n "$suffix" ]] && record_value="${prefix}${suffix}"  # Use prefix + suffix for custom AAAA records
        fi

        # Ensure the record value is valid before proceeding
        if [[ -z "$record_value" || "$record_value" == "Unavailable" ]]; then
            printf "\n\nWarning: Invalid value for record '%s'. Skipping.\n" "$record_fqdn" >&2
            continue
        fi

        # Manage the record (create or update)
        cf_manage_record "$record_fqdn" "$record_type" "$record_value" || {
            printf "\n\nError: Failed to process record '%s'.\n" "$record_fqdn" >&2
        }
    done
}


# Main loop to periodically check and update DNS records
while true; do
    bashio::cache.flush_all

    # IPv6 handling: Loop through all IPv6 addresses and process the valid one
    for getv6 in $(bashio::network.ipv6_address); do
        if [[ "$getv6" != fe80* && "$getv6" != fc* && "$getv6" != fd* && "${legacyMode}" != true ]]; then
            v6new="${getv6%%/*}"  # Remove the prefix length from the IPv6 address
            prefixTmp=$(echo "$v6new" | cut -d':' -f1-$hextets)  # Extract the prefix portion of the address
            nextHextet=$(echo "$v6new" | cut -d':' -f$((hextets + 1)))  # Get the next hextet after the prefix
            paddedNextHextet=$(printf "%04s" "$nextHextet")  # Pad the hextet with leading zeros if necessary
            remainder=$((prefixLength % 16))  # Calculate the remainder for the prefix

            # Adjust the prefix based on the remainder (partial hextet handling)
            if [ "$remainder" -ne 0 ]; then
                cut_length=$((remainder / 4))
                prefix="${prefixTmp}:$(echo "$paddedNextHextet" | cut -c1-$cut_length)"
            else
                prefix="${prefixTmp}:"
            fi
            break  # Stop after the first valid address
        fi
    done

    # If no valid IPv6 address is found, set to "Unavailable"
    if [[ -z "$v6new" ]]; then
        v6new="Unavailable"
        prefix="Unavailable"
    fi

    # Get the public IPv4 address using Cloudflare's trace service
    getv4=$(curl -s -4 https://one.one.one.one/cdn-cgi/trace | grep 'ip=' | cut -d'=' -f2)
    if [[ "${getv4}" == *.*.*.* && "${v4Enabled}" == true ]]; then
        v4new="${getv4}"  # Set the new IPv4 address
    else
        v4new="Unavailable"  # Set IPv4 to "Unavailable" if not found or disabled
    fi

    # If both IPv6 and IPv4 are unavailable, count as failure
    if [[ "${v6new}" == "Unavailable" && "${v4new}" == "Unavailable" ]]; then
        successCount=0
        ((failCount+= 1))  # Increment failure count
        echo -e "\n\nNo Internet Connection detected for $((refreshMin * failCount)) minutes. Trying again in ${refreshMin} minutes!"
    else
        # Reset failure count and increment success count
        failCount=0
        ((successCount += 1))

        # If IP addresses have changed, update the DNS records
        if [[ "${v6new}" != "${v6}" || "${v4new}" != "${v4}" ]]; then
            v6="${v6new}"  # Update stored IPv6 address
            v4="${v4new}"  # Update stored IPv4 address
            echo -e "\n\nYour new public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"

            # Update DNS records for the main FQDN if configured
            if [[ -n "${hostfqdn}" ]]; then
                [[ "${legacyMode}" == false && "${v6}" != "Unavailable" ]] && cf_manage_record "${hostfqdn}" "AAAA" "${v6}"
                [[ ${v4Enabled} == true && "${v4}" != "Unavailable" ]] && cf_manage_record "${hostfqdn}" "A" "${v4}"
            fi

            # Update custom DNS records if enabled
            [[ ${customEnabled} == true ]] && parse_records

            echo -e "\n\nUpdated records. Waiting ${refreshMin} minutes until the next update"
            successCount=0  # Reset success counter after update
        else
            # IPs haven't changed, just print a message
            echo -e "\n\nIPs haven't changed since $((refreshMin * successCount)) minutes. Waiting ${refreshMin} minutes until the next update"
            echo "Your public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"
        fi
    fi

    # Wait for the refresh interval before the next check
    sleep "${refresh}"
done
# (C) GitHub\TKtheDEV