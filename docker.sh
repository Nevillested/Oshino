docker stop oshino 2>/dev/null || true
docker rm oshino 2>/dev/null || true
docker build --no-cache -t oshino .
docker run -d \
  --name=oshino \
  --restart=unless-stopped \
  -p 8080:8080 \
  --network=apps \
  -e TZ=Asia/Tokyo \
  oshino
