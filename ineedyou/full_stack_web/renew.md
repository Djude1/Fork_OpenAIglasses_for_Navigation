# 更新日志 (Renew Log)

本文件用于记录每次代码更新的内容，以及你需要执行的操作。

## 2024-05-20 (修复后端崩溃导致无法登录的问题)

### 我做了什么 (What I did):
1. **修复了后端容器启动崩溃的问题**:
   - **原因分析**: 你在 Windows 上使用 Git 下载代码时，Git 会自动将文本文件的换行符从 Unix 格式 (`LF`) 转换成 Windows 格式 (`CRLF`)。这导致 Linux Docker 容器在执行 `entrypoint.sh` 脚本时报错 `\r: command not found`，从而导致 Django 后端容器启动失败并直接退出。
   - **修复方法**: 我修改了 `backend/Dockerfile`，在构建镜像时安装了 `dos2unix` 工具，并自动将 `entrypoint.sh` 转换回 Unix 的换行格式。
2. **补充了 Django 缺失的模块文件**:
   - 之前创建目录时遗漏了 Python 包必须的 `__init__.py` 文件以及 Django App 的 `apps.py` 文件。这会导致 Django 无法识别 `users` 和 `devices` 模块。我已经补充了这些文件。

> **为什么你之前前端显示正常但无法登录？**
> 因为前端 (Nginx, 端口 3000) 成功启动了，但后端 (Django, 端口 8000) 因为上述的换行符错误和文件缺失错误，根本没有启动。所以当你访问 `:8000` 时无法连线，当你在前端点击登录时，请求发往了一个不存在的后端服务，导致登录失败。

### 你需要做什么 (What you need to do):

为了让上述修复生效，你需要**完全重建**后端的 Docker 镜像。请在 `ineedyou/full_stack_web` 目录下执行以下命令：

1. **停止并清理现有环境** (这会删除旧的容器和数据库卷，确保我们从头开始干净的环境)：
   ```bash
   docker-compose down -v
   ```

2. **拉取最新代码** (如果你是通过 Git 管理的)：
   ```bash
   git pull
   ```

3. **重新构建并启动服务** (强制重新构建镜像，应用 Dockerfile 的修改)：
   ```bash
   docker-compose up -d --build
   ```

4. **验证**：
   - 稍等 10 秒钟左右让数据库和后端启动。
   - 打开浏览器访问 `http://localhost:8000/api/` 或 `http://localhost:8000/admin/`，确认现在可以正常显示 Django 的页面。
   - 访问 `http://localhost:3000/login`，使用 `admin` / `admin123` 或 `user1` / `user123` 进行登录，现在应该可以成功进入 Dashboard 了。
