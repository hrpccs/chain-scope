FROM python:3.11-slim


WORKDIR /app

COPY . .

# Install build dependencies and protoc
RUN pip install --no-cache-dir grpcio grpcio-tools protobuf
RUN pip install --no-cache-dir -r requirements_http.txt

ENV PYTHONUNBUFFERED=1

EXPOSE 4318
EXPOSE 4317

CMD ["python", "-u", "main.py"]
