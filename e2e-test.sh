#!/usr/bin/env bash
set -e

COMPOSE_FILE="docker-compose.e2e.yml"
BACKEND_URL="http://localhost:8000"

echo "=========================================="
echo "  Tantor E2E Test Environment"
echo "=========================================="
echo ""

# Build and start containers
echo "▶ Building and starting containers..."
docker compose -f "$COMPOSE_FILE" up --build -d

# Wait for backend to be healthy
echo ""
echo "▶ Waiting for backend to be ready..."
for i in $(seq 1 30); do
    if curl -sf "$BACKEND_URL/api/health" > /dev/null 2>&1; then
        echo "  ✓ Backend is ready!"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ Backend failed to start within 60 seconds"
        echo "  Check logs: docker compose -f $COMPOSE_FILE logs backend"
        exit 1
    fi
    sleep 2
done

# Wait for SSH on nodes
echo ""
echo "▶ Waiting for SSH nodes..."
for port in 2201 2202; do
    for i in $(seq 1 15); do
        if nc -z localhost "$port" 2>/dev/null || (echo > /dev/tcp/localhost/"$port") 2>/dev/null; then
            echo "  ✓ Port $port is ready"
            break
        fi
        if [ "$i" -eq 15 ]; then
            echo "  ✗ Port $port not reachable"
        fi
        sleep 1
    done
done

# Print info
echo ""
echo "=========================================="
echo "  Environment Ready!"
echo "=========================================="
echo ""
echo "  Backend API:  $BACKEND_URL"
echo "  Frontend:     Run 'cd frontend && npm run dev' locally"
echo "                Then open http://localhost:5173"
echo ""
echo "  Login:        admin / admin"
echo ""
echo "  Node 1:       172.30.0.11 (SSH port 2201)"
echo "  Node 2:       172.30.0.12 (SSH port 2202)"
echo "  Node user:    root / tantor123"
echo ""
echo "  ─────────────────────────────────────"
echo "  E2E Test Steps:"
echo "  ─────────────────────────────────────"
echo "  1. Open http://localhost:5173 → Login (admin/admin)"
echo "  2. Go to Hosts → Add Host:"
echo "     • hostname=node1, ip=172.30.0.11, port=22"
echo "     • username=root, auth=password, password=tantor123"
echo "  3. Repeat for node2 (ip=172.30.0.12)"
echo "  4. Test connectivity on both hosts"
echo "  5. Create cluster (KRaft mode)"
echo "  6. Add services: node1=broker_controller(id=1),"
echo "     node2=broker_controller(id=2)"
echo "  7. Deploy → watch logs → should succeed"
echo ""
echo "  Tear down:  docker compose -f $COMPOSE_FILE down -v"
echo ""
