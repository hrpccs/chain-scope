NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[0].address}")
PORT=$(kubectl get --namespace deepflow -o jsonpath="{.spec.ports[0].nodePort}" services deepflow-server)

sql="SELECT  Count(row) FROM l7_flow_log WHERE endpoint = '/profile.Profile/GetProfiles' AND observation_point = 'c-p';"
profile_total=$(curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
    --data-urlencode "db=flow_log" \
    --data-urlencode "sql=${sql}" | jq -r '.result.values[0][0]')
sql="SELECT Count(row) FROM l7_flow_log WHERE endpoint = '/profile.Profile/GetProfiles' AND observation_point = 'c-p' AND request_id IN (SELECT request_id FROM flow_log.l7_flow_log WHERE  endpoint = '/profile.Profile/GetProfiles' AND observation_point = 's-p') AND req_tcp_seq = l7_flow_log.req_tcp_seq"
profile_correct=$(curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
    --data-urlencode "db=flow_log" \
    --data-urlencode "sql=${sql}" | jq -r '.result.values[0][0]')
sql="SELECT  Count(row) FROM l7_flow_log WHERE endpoint = '/recommendation.Recommendation/GetRecommendations' AND observation_point = 'c-p';"
recommendation_total=$(curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
    --data-urlencode "db=flow_log" \
    --data-urlencode "sql=${sql}" | jq -r '.result.values[0][0]')
sql="SELECT Count(row) FROM l7_flow_log WHERE endpoint = '/recommendation.Recommendation/GetRecommendations' AND observation_point = 'c-p' AND request_id IN (SELECT request_id FROM flow_log.l7_flow_log WHERE  endpoint = '/recommendation.Recommendation/GetRecommendations' AND observation_point = 's-p') AND req_tcp_seq = l7_flow_log.req_tcp_seq"
recommendation_correct=$(curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
    --data-urlencode "db=flow_log" \
    --data-urlencode "sql=${sql}" | jq -r '.result.values[0][0]')

# echo "profile_total: ${profile_total}"
# echo "profile_correct: ${profile_correct}"
# echo "recommendation_total: ${recommendation_total}"
# echo "recommendation_correct: ${recommendation_correct}"
# echo "profile_accuracy: ${profile_correct}/${profile_total}"
# echo "recommendation_accuracy: ${recommendation_correct}/${recommendation_total}"

total=$((${profile_total}+${recommendation_total}))
correct=$((${profile_correct}+${recommendation_correct}))
profile_loss=$((${profile_total}-${profile_correct}))
recommendation_loss=$((${recommendation_total}-${recommendation_correct}))
intra_node_loss_rate_pct=$(echo "scale=2; (${profile_loss} * 100 /${total}) " | bc)
echo "intra_node_loss_count: ${profile_loss}"
inter_node_loss_rate_pct=$(echo "scale=2; (${recommendation_loss} * 100 /${total}) " | bc)
echo "inter_node_loss_count: ${recommendation_loss}"
echo "intra_node_loss_rate_pct: ${intra_node_loss_rate_pct}%"
echo "inter_node_loss_rate_pct: ${inter_node_loss_rate_pct}%"
accuracy=$(echo "scale=2; (${correct} * 100 /${total}) " | bc)
echo "total: ${total}"
echo "correct ${correct}"
echo "profile_total ${profile_total}"
echo "profile_correct ${profile_correct}"
echo "recommendation_total ${recommendation_total}"
echo "recommendation_correct ${recommendation_correct}"
echo "accuracy: ${accuracy}%"

# sql="SELECT Count(row) FROM l7_flow_log WHERE endpoint = '/profile.Profile/GetProfiles' AND observation_point = 'c-p' AND request_id IN (SELECT request_id FROM flow_log.l7_flow_log WHERE  endpoint = '/profile.Profile/GetProfiles' AND observation_point = 's-p' AND req_tcp_seq = l7_flow_log.req_tcp_seq)"
# curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
#     --data-urlencode "db=flow_log" \
#     --data-urlencode "sql=${sql}" 

# sql="SELECT Count(row) FROM l7_flow_log WHERE endpoint = '/recommendation.Recommendation/GetRecommendations' AND observation_point = 'c-p' AND request_id IN (SELECT request_id FROM flow_log.l7_flow_log WHERE  endpoint = '/recommendation.Recommendation/GetRecommendations' AND observation_point = 's-p' AND req_tcp_seq = l7_flow_log.req_tcp_seq)"
# curl -s -XPOST "http://${NODE_IP}:${PORT}/v1/query/" \
#     --data-urlencode "db=flow_log" \
#     --data-urlencode "sql=${sql}" 