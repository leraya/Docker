#!/bin/bash
set -e

PROJECT_NAME="hw3_test_$$"
ENV_FILE=$(mktemp)
# Задаем тестовый порт, отличный от основного (например, 8081)
TEST_PORT="8081"

# Принудительно указываем порт для тестового запуска
echo "APP_PORT=$TEST_PORT" > "$ENV_FILE"

cleanup() {
    echo "--- Очистка тестовых ресурсов ---"
    docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" down -v >/dev/null 2>&1 || true
    rm -f "$ENV_FILE"
}
trap cleanup EXIT

echo "--- Этап 1: Создание отдельного тестового проекта ---"
docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" up -d --build

echo "Ожидание готовности приложения..."
for i in {1..30}; do
    # Проверяем именно тестовый порт
    if curl -fsS --max-time 2 http://127.0.0.1:$TEST_PORT/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
    if [ $i -eq 30 ]; then echo "Ошибка: Приложение не запустилось"; exit 1; fi
done

echo "--- Этап 2: Проверка исходного счетчика ---"
COUNT=$(curl -fsS --max-time 2 http://127.0.0.1:$TEST_PORT/ | grep -o '"count": *[0-9]*' | grep -o '[0-9]*')
if [ "$COUNT" != "0" ]; then echo "Ошибка: Исходный счетчик не равен 0"; exit 1; fi

for i in {1..5}; do curl -fsS -X POST --max-time 2 http://127.0.0.1:$TEST_PORT/increment >/dev/null; done

COUNT=$(curl -fsS --max-time 2 http://127.0.0.1:$TEST_PORT/ | grep -o '"count": *[0-9]*' | grep -o '[0-9]*')
if [ "$COUNT" != "5" ]; then echo "Ошибка: Счетчик не равен 5 после запросов"; exit 1; fi
echo "Успех: Счетчик равен 5"

echo "--- Этап 3: Пересоздание контейнера app ---"
docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" up -d --force-recreate app
sleep 3

COUNT=$(curl -fsS --max-time 2 http://127.0.0.1:$TEST_PORT/ | grep -o '"count": *[0-9]*' | grep -o '[0-9]*')
if [ "$COUNT" != "5" ]; then echo "Ошибка: Счетчик сбросился после пересоздания!"; exit 1; fi
echo "Успех: Счетчик сохранился (5)"

echo "--- Этап 4: Проверка отключения Redis ---"
docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" stop redis >/dev/null 2>&1
sleep 2
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:$TEST_PORT/readyz)
if [ "$STATUS" != "503" ]; then echo "Ошибка: readyz не вернул 503 при упавшем Redis"; exit 1; fi

docker compose -p "$PROJECT_NAME" --env-file "$ENV_FILE" start redis >/dev/null 2>&1
sleep 3
curl -fsS --max-time 2 http://127.0.0.1:$TEST_PORT/ >/dev/null
echo "Успех: Приложение восстановилось после старта Redis"

echo "--- Этап 5: Резервное копирование ---"
BACKUP_FILE="backup_$$.tar.gz"
docker run --rm -v "${PROJECT_NAME}_redis-data":/data -v $(pwd):/backup alpine tar czf /backup/$BACKUP_FILE -C /data .
if [ ! -f "$BACKUP_FILE" ]; then echo "Ошибка: Бэкап не создан"; exit 1; fi
echo "Успех: Бэкап создан ($BACKUP_FILE)"
rm -f "$BACKUP_FILE"

echo "--- Все проверки пройдены успешно! ---"
