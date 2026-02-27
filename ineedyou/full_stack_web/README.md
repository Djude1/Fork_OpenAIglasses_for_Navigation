# AI Glass Full Stack Web System

This is a comprehensive full-stack system designed to manage the AI Glass devices, users, and logs. It uses:

-   **Backend**: Django (Python) + Django REST Framework.
-   **Frontend**: React (JavaScript/TypeScript) + Material UI.
-   **Database**: PostgreSQL.
-   **Deployment**: Docker Compose.

## How to Run

1.  **Navigate to the folder**:
    ```bash
    cd ineedyou/full_stack_web
    ```

2.  **Start the services**:
    ```bash
    docker-compose up -d --build
    ```
    This command will build the backend and frontend images, start the PostgreSQL database, and bring up the entire stack.

3.  **Access the System**:
    -   **Frontend**: Open your browser and go to `http://localhost:3000`.
    -   **Backend API**: `http://localhost:8000/api/` (Browseable API).
    -   **Admin Panel**: `http://localhost:8000/admin/`.

## Default Credentials

### Superuser (Admin)
-   **Username**: `admin`
-   **Password**: `admin123`
-   **Email**: `admin@example.com`

### Regular User
-   **Username**: `user1`
-   **Password**: `user123`
-   **Email**: `user1@example.com`

## Features

-   **User Authentication**: Login/Register/Logout using JWT tokens.
-   **Role-Based Access**:
    -   **Admin**: Can manage all users, view all device logs, and configure system settings.
    -   **User**: Can view their own device status, logs, and update profile.
-   **Device Management**: Register and monitor AI Glass devices.
-   **Log Viewer**: Historical data of OCR scans, navigation events, and errors.

## Development

-   **Backend**: Located in `backend/`. Uses Django.
-   **Frontend**: Located in `frontend/`. Uses React (create-react-app or Vite).
-   **Database**: Data is persisted in a Docker volume `postgres_data`.

## Stopping the System

To stop the containers:
```bash
docker-compose down
```
To stop and remove volumes (reset database):
```bash
docker-compose down -v
```
