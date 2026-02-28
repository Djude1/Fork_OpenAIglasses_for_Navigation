# 更新日志 (Renew Log)

本文件用于记录每次代码更新的内容，以及你需要执行的操作。

## 2024-05-20 (修复 Django 缺失 wsgi.py 导致 Web 服务器无法启动的问题)

### 我做了什么 (What I did):
非常感谢你提供了详细的日志！日志清晰地指出了最后一步的死因：
`django.core.exceptions.ImproperlyConfigured: WSGI application 'config.wsgi.application' could not be loaded; Error importing module.`
这表示数据库初始化、用户创建（admin, user1）全都**成功**了，但是在最后执行 `python manage.py runserver 0.0.0.0:8000` 启动 Web 服务器时，找不到 `config/wsgi.py` 文件。
- 我之前纯手工搭建 Django 目录时，遗漏了生成这个用于启动 HTTP 服务的核心网关文件。
- 我现在已经补充了 `backend/config/wsgi.py` 和 `backend/config/asgi.py` 文件。

### 你需要做什么 (What you need to do):

胜利就在眼前，请执行最后一次拉取和启动：

1. **拉取最新代码**：
   ```bash
   git pull
   ```

2. **不需要重新构建镜像，直接重启服务即可**（因为这次只是加了一个 Python 代码文件，如果你本地用的是卷挂载，甚至不需要重启，但为了保险起见，我们重启一下）：
   ```bash
   docker-compose down
   docker-compose up -d
   ```

3. **验证**：
   - 访问 `http://localhost:8000/api/`，你应该能看到 Django REST Framework 的 API 界面了！
   - 访问 `http://localhost:3000/login`，输入账号 `admin` 密码 `admin123`，现在肯定能登录成功了。
