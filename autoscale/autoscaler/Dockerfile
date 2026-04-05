FROM docker:27-cli

RUN apk add --no-cache bash curl jq

COPY autoscale.sh /app/autoscale.sh
RUN chmod +x /app/autoscale.sh

WORKDIR /app
ENTRYPOINT ["/app/autoscale.sh"]
