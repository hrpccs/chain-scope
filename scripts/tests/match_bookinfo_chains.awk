#!/usr/bin/awk -f

BEGIN {
    if (istio == "true" || istio == "True" || istio == 1) {
        ValidChains["IN -> envoy -> productpage-v1 -> envoy -> envoy -> details-v1 -> envoy -> envoy -> productpage-v1 -> envoy -> envoy -> reviews-v1 -> envoy -> envoy -> productpage-v1 -> envoy -> OUT"] = 1
        ValidChains["IN -> envoy -> productpage-v1 -> envoy -> envoy -> details-v1 -> envoy -> envoy -> productpage-v1 -> envoy -> envoy -> reviews-v2 -> envoy -> envoy -> ratings-v1 -> envoy -> envoy -> reviews-v2 -> envoy -> envoy -> productpage-v1 -> envoy -> OUT"] = 1
        ValidChains["IN -> envoy -> productpage-v1 -> envoy -> envoy -> details-v1 -> envoy -> envoy -> productpage-v1 -> envoy -> envoy -> reviews-v3 -> envoy -> envoy -> ratings-v1 -> envoy -> envoy -> reviews-v3 -> envoy -> envoy -> productpage-v1 -> envoy -> OUT"] = 1
    } else {
        ValidChains["IN -> productpage-v1 -> details-v1 -> productpage-v1 -> reviews-v1 -> productpage-v1 -> OUT"] = 1
        ValidChains["IN -> productpage-v1 -> details-v1 -> productpage-v1 -> reviews-v2 -> ratings-v1 -> reviews-v2 -> productpage-v1 -> OUT"] = 1
        ValidChains["IN -> productpage-v1 -> details-v1 -> productpage-v1 -> reviews-v3 -> ratings-v1 -> reviews-v3 -> productpage-v1 -> OUT"] = 1
    }
}

{
    Pass = 0
    matched = 0
    original_line = $0
    $1 = ""
    sub(/^ /, "")

    for (str in ValidChains) {
        if (index($0, str) > 0) {
            matched = 1
            break
        }
    }

    print original_line
    if (!matched) {
        print "Chain " NR " does not match any of the expected patterns."
        exit 1
    }
    Pass = 1
}

END {
    if (Pass == 1) {
        print "All chains match the expected patterns."
    }
}
