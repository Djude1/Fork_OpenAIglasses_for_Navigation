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
echo "Creating default users and generating tokens..."
python manage.py shell <<EOF
import os
import django
from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token

User = get_user_model()
try:
    admin_user, created = User.objects.get_or_create(username='admin', defaults={'email': 'admin@example.com'})
    if created:
        admin_user.set_password('admin123')
        admin_user.is_staff = True
        admin_user.is_superuser = True
        admin_user.save()
        print("Superuser 'admin' created successfully.")
    else:
        # Update password just in case it was wrong
        admin_user.set_password('admin123')
        admin_user.save()
        print("Superuser 'admin' already exists (password reset to default).")

    # Generate token
    Token.objects.get_or_create(user=admin_user)

    regular_user, created = User.objects.get_or_create(username='user1', defaults={'email': 'user1@example.com'})
    if created:
        regular_user.set_password('user123')
        regular_user.save()
        print("User 'user1' created successfully.")
    else:
        # Update password just in case
        regular_user.set_password('user123')
        regular_user.save()
        print("User 'user1' already exists (password reset to default).")

    # Generate token
    Token.objects.get_or_create(user=regular_user)

except Exception as e:
    print(f"Error creating users: {e}")
EOF

echo "Starting server..."
exec python manage.py runserver 0.0.0.0:8000
