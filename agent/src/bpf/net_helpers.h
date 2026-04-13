#ifndef NET_HELPERS_H
#define NET_HELPERS_H

#define AF_INET			2
#define AF_INET6		10

// check big endian or little endian
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
# define __bpf_htons(x)                 __builtin_bswap16(x)
# define __bpf_ntohs(x)                __builtin_bswap16(x)
# define __bpf_ntohl(x)               __builtin_bswap32(x)
# define __bpf_htonl(x)                __builtin_bswap32(x)
# define __bpf_ntohll(x)               __builtin_bswap64(x)
# define __bpf_htonll(x)              __builtin_bswap64(x)
#elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
# define __bpf_htons(x)                 (x)
# define __bpf_ntohs(x)                (x)
# define __bpf_htonl(x)                 (x)
# define __bpf_ntohl(x)                (x)
# define __bpf_htonll(x)               (x)
# define __bpf_ntohll(x)               (x)
#else
# error "Fix your compiler's __BYTE_ORDER__?!"
#endif


#define ETH_ALEN 6
#define ETH_P_802_3_MIN 0x0600
#define ETH_P_8021Q 0x8100
#define ETH_P_8021AD 0x88A8
#define ETH_P_IP 0x0800
#define ETH_P_IPV6 0x86DD
#define ETH_P_ARP 0x0806
#define IPPROTO_ICMPV6 58

#define TC_ACT_OK		0
#define TC_ACT_SHOT		2

#define IFNAMSIZ 16

#define ETH_HLEN sizeof(struct ethhdr)
#define IP_HLEN sizeof(struct iphdr)
#define TCP_HLEN sizeof(struct tcphdr)

#define MSG_PEEK 0x2

#endif