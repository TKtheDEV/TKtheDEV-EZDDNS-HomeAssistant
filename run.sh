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
    fqdn=$1  # Fully qualified domain name (FQDN)
    record_type=$2  # DNS record type (A or AAAA)
    record_value=$3  # The value for the DNS record (IPv4 or IPv6)

    # Make the API call and filter for the 'id' field containing a 32-char hex string
    record_id=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records?type=${record_type}&name=${fqdn}" \
    -H "Authorization: Bearer ${apiToken}" \
    -H "Content-Type: application/json" \
    | grep -oE '"id":"[0-9a-fA-F]{32}"' \
    | grep -oE '[0-9a-fA-F]{32}')

    # Check if we found a valid ID
    if [[ $record_id =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "Record exists with ID: $record_id"
        # Update the record
        curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records/${record_id}" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    else
        echo "Record does not exist, creating new record"
        # Create the record
        curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records" \
        -H "Authorization: Bearer ${apiToken}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"${record_type}\",\"name\":\"${fqdn}\",\"content\":\"${record_value}\",\"ttl\":${dnsttl},\"proxied\":${proxied}}"
    fi
}

# Function to process custom DNS records
parse_records() {
    echo "$customRecords" | while IFS=, read -r record_fqdn record_type suffix; do
        # Determine the appropriate value (IPv4 or IPv6) for the record
        record_value="${v6}"  # Default to IPv6
        [[ "$record_type" == "A" ]] && record_value="${v4}"  # Use IPv4 for "A" records
        [[ "$record_type" == "AAAA" && -n "$suffix" ]] && record_value="${prefix}${suffix}"  # Use prefix + suffix for custom AAAA records

        # Manage the record (create or update)
        cf_manage_record "$record_fqdn" "$record_type" "$record_value"
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
        echo "No Internet Connection detected for $((refreshMin * failCount)) minutes. Trying again in ${refreshMin} minutes!"
    else
        # Reset failure count and increment success count
        failCount=0
        ((successCount += 1))

        # If IP addresses have changed, update the DNS records
        if [[ "${v6new}" != "${v6}" || "${v4new}" != "${v4}" ]]; then
            v6="${v6new}"  # Update stored IPv6 address
            v4="${v4new}"  # Update stored IPv4 address
            echo "Your new public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"

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
            echo -e "\nIPs haven't changed since $((refreshMin * successCount)) minutes. Waiting ${refreshMin} minutes until the next update"
            echo "Your public IP config: Prefix: ${prefix} IPv6: ${v6} IPv4: ${v4}"
        fi
    fi

    # Wait for the refresh interval before the next check
    sleep "${refresh}"
done
# (C) GitHub\TKtheDEV