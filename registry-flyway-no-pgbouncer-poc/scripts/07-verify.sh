#!/usr/bin/env bash
set -euo pipefail

echo "Event-store events:"
docker exec registry-event-postgres \
  psql -U registry -d registry_events \
  -c "select sequence, event_type, stream_id, event_data, correlation_id from domain_events order by sequence;"

echo
echo "Event-store Flyway history:"
docker exec registry-event-postgres \
  psql -U registry -d registry_events \
  -c "select installed_rank, version, description, success from flyway_schema_history order by installed_rank;"

echo
echo "Read-store company read model:"
docker exec registry-read-postgres \
  psql -U registry -d registry_read \
  -c "select company_number, company_name, registered_address, status, last_event_id from company_read_model order by company_number;"

echo
echo "Read-store Flyway history:"
docker exec registry-read-postgres \
  psql -U registry -d registry_read \
  -c "select installed_rank, version, description, success from flyway_schema_history order by installed_rank;"
