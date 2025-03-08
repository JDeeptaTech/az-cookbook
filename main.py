import os
from azure.identity import ClientSecretCredential
from azure.mgmt.resource import SubscriptionClient
from openai import OpenAI
from azure.mgmt.network import NetworkManagementClient
import ipaddress

# SPN Credentials
TENANT_ID = os.getenv("AZ_TENANT_ID")
CLIENT_ID = os.getenv("AZ_CLIENT_ID")
CLIENT_SECRET = os.getenv("AZ_CLIENT_SECRET")
azure_arm_url = "https://management.azure.com/"
azure_arm_scope = "https://management.azure.com/.default"

# Authenticate
credentials = ClientSecretCredential(TENANT_ID, CLIENT_ID, CLIENT_SECRET)

# Initialize Azure SDK clients
# Get Virtual Networks
subscription_client = SubscriptionClient(
    credential=credentials, base_url=azure_arm_url, credential_scopes=[azure_arm_scope]
)


def find_vnet_gaps(vnets):
    """
    Finds unused IP ranges within each VNet's address prefixes.

    :param vnets: List of VNets, each with 'address_prefixes' and 'subnets'.
    :return: List of VNets with 'gaps' field updated.
    """
    for vnet in vnets:
        address_spaces = [
            ipaddress.ip_network(cidr, strict=False)
            for cidr in vnet.get("address_prefixes", [])
        ]
        subnets = [
            ipaddress.ip_network(subnet_cidr, strict=False)
            for subnet in vnet.get("subnets", [])
            for subnet_cidr in subnet.get("address_prefixes", [])
        ]

        gaps = []

        for vnet_space in address_spaces:
            # Filter subnets belonging to this address space
            relevant_subnets = [s for s in subnets if vnet_space.overlaps(s)]
            relevant_subnets.sort(key=lambda x: x.network_address)

            current_address = vnet_space.network_address

            for subnet in relevant_subnets:
                if subnet.network_address > current_address:
                    gaps.append(f"{current_address} - {subnet.network_address - 1}")
                current_address = subnet.broadcast_address + 1

            # Check for gap at the end of the address space
            if current_address <= vnet_space.broadcast_address:
                gaps.append(f"{current_address} - {vnet_space.broadcast_address}")

        # get the ip_range_to_cidr for the gaps, along with gaps
        vnet["gaps"] = [
            {"gap": gap, "cidr": ip_range_to_cidr(*gap.split(" - "))} for gap in gaps
        ]

    return vnets


def count_ip_addresses(cidr):
    """
    Calculates the number of IP addresses in a given CIDR block.

    Args:
      cidr: The CIDR block in string format (e.g., "192.168.1.0/24").

    Returns:
      The number of IP addresses in the CIDR block.
    """
    try:
        ip_network = ipaddress.ip_network(cidr)
        return ip_network.num_addresses
    except ValueError:
        print(f"Invalid CIDR block: {cidr}")
        return 0



def ip_range_to_cidr(start_ip, end_ip):
    """
    Converts an IP address range to a list of CIDR blocks.

    Args:
        start_ip: The starting IP address (string).
        end_ip: The ending IP address (string).

    Returns:
        A list of CIDR blocks that cover the range.
    """
    try:
        start_int = int(ipaddress.ip_address(start_ip))
        end_int = int(ipaddress.ip_address(end_ip))
        if start_int > end_int:
            raise ValueError("Start IP must be less than or equal to end IP.")

        return [
            str(net)
            for net in ipaddress.summarize_address_range(
                ipaddress.ip_address(start_int), ipaddress.ip_address(end_int)
            )
        ]
    except ValueError as e:
        return [f"Error: {e}"]


subs = []
for sub in subscription_client.subscriptions.list():
    subs.append(
        {
            "id": sub.id,
            "name": sub.display_name,
            "subscription_id": sub.subscription_id,
            "tenant_id": sub.tenant_id,
            "tags": sub.tags,
        }
    )

vnet_data = []
for hub in subs:
    network_client = NetworkManagementClient(
        credential=credentials,
        subscription_id=hub["subscription_id"],
        base_url=azure_arm_url,
        credential_scopes=[azure_arm_scope],
    )

    vnets = network_client.virtual_networks.list_all()
    for vnet in vnets:
        vnet_data.append(
            {
                "subscription_id": hub["subscription_id"],
                "hub_name": hub["name"],
                "hub_id": hub["id"],
                "hub_tenant_id": hub["tenant_id"],
                "hub_tags": hub["tags"],
                "name": vnet.name,
                "location": vnet.location,
                "address_prefixes": vnet.address_space.address_prefixes,
                "address_count": sum(
                    count_ip_addresses(cidr)
                    for cidr in vnet.address_space.address_prefixes
                ),
                "tags": vnet.tags,
                "subnets": [
                    {
                        "name": subnet.name,
                        "address_prefixes": subnet.address_prefixes,
                        "address_count": sum(
                            count_ip_addresses(cidr) for cidr in subnet.address_prefixes
                        ),
                    }
                    for subnet in vnet.subnets
                ],
                "gaps": [],
            }
        )
    network_client.close()

subscription_client.close()

# Find gaps
updated_vnets = find_vnet_gaps(vnet_data)

# Print results
for vnet in updated_vnets:
    print(f"VNet: {vnet['name']} (Location: {vnet['location']})")
    print(f"  Address Prefixes: {vnet['address_prefixes']}")
    print(f"  Total IP Addresses: {vnet['address_count']}")
    print(f"  Tags: {vnet['tags']}")
    print(
        f"  Subnets: {[(subnet['name'], subnet['address_prefixes'], subnet['address_count'])  for subnet in vnet['subnets']]}"
    )
    print(f"  Gaps: {vnet['gaps']}\n")

