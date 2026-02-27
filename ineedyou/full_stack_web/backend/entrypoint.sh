#!/bin/bash
set -e

echo "Waiting for PostgreSQL at $DB_HOST:$DB_PORT..."
# Wait for the database to be ready
while ! nc -z $DB_HOST $DB_PORT; do
  sleep 1
done
echo "PostgreSQL started"

# Apply database migrations
echo "Applying migrations..."
python manage.py makemigrations users devices
python manage.py migrate

# Create default users using a Python script inside Django's shell context
echo "Creating default users..."
python manage.py shell <<EOF
import os
import django
from django.contrib.auth import get_user_model

User = get_user_model()
try:
    if not User.objects.filter(username='admin').exists():
        User.objects.create_superuser('admin', 'admin@example.com', 'admin123')
        print("Superuser 'admin' created.")
    else:
        print("Superuser 'admin' already exists.")

    if not User.objects.filter(username='user1').exists():
        User.objects.create_user('user1', 'user1@example.com', 'user123')
        print("User 'user1' created.")
    else:
        print("User 'user1' already exists.")
except Exception as e:
    print(f"Error creating users: {e}")
EOF

echo "Starting server..."
exec python manage.py runserver 0.0.0.0:8000
