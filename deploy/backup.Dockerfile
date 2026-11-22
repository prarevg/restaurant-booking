FROM postgres:16-alpine
RUN apk add --no-cache curl jq
COPY backup.sh /usr/local/bin/booking-backup
RUN chmod 755 /usr/local/bin/booking-backup
ENTRYPOINT ["/usr/local/bin/booking-backup"]
