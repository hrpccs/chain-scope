get_registry() {
  echo chainscope1234
}

IMAGE_REGISTRY=$(get_registry)

# docker build . -t "${IMAGE_REGISTRY}"/hotelreservation:notracing-with-symbol
# docker push "${IMAGE_REGISTRY}"/hotelreservation:notracing-with-symbol

docker build . -t "${IMAGE_REGISTRY}"/hotelreservation:bench
docker push "${IMAGE_REGISTRY}"/hotelreservation:bench