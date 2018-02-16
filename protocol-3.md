# Minitel - Layer 3

## Language
Node - a device of some description on a Minitel network, ie a computer, server, microcontroller or drone.

## Behavior

### Receiving
Upon a node receiving a message addressed to itself, it should:

1. Check if the packet ID has been seen before, and if so, drop the packet
2. Check if the packet is addressed to the node, and if so, queue it as a net_msg event
3. If the packet is indeed addressed to this node, and the packet type is 1 (reliable), send an acknowledgement packet.
4. Optional: Add the sender to the address cache if it isn't already in the cache
5. Optional: If the packet is addressed to a different node, repeat the packet, preferably respecting the address cache

### Optional: Meshing
If a message is not addressed to a node, and the node has not seen the packet ID before, the node should repeat it. Whether via the address in the cache or by broadcast, it should be passed on, and the hardware address added to the cache as the sender.

### Optional: Address caching
Each machine should keep a last known route cache. The exact format is up to the implementation, but it will need:

- hostname
- hardware address
- time when added to cache

It is recommended to keep the data in the cache for 30 seconds or so, then drop it, though being user-configurable is ideal.

When sending a message, check the cache for the given destination. If there is a hardware address in the cache for the destination, send the message straight to that address. Otherwise, broadcast the message.

## Packet Format
Packets are made up of separated parts, as allowed by OpenComputers modems.

- packetID: random string to differentiate packets from each other
- packetType, number:
 0. unreliable
 1. reliable, requires acknowledgement
 2. acknowledgement packet
- destination: end destination hostname, string
- sender: original sender of packet, string
- port: virtual port, number \< 65536
- data: the actual packet data, or in the case of an acknowledgement packet, the original packet ID, string

### Example exchange:

Node bob sends a reliable packet to node alice, on port 44:  
"asdsfghjkqwertyu", 1, "alice", "bob", 44, "Hello!"

Node alice acknowledges node bob's packet:  
"1234567890asdfgh", 2, "bob", "alice", 44, "asdsfghjkqwertyu"