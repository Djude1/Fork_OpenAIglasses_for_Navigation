# 更新日志 (Renew Log)

本文件用于记录每次代码更新的内容，以及你需要执行的操作。

## 2024-05-20 (修复 Docker Volume 挂载导致的 `entrypoint.sh` 找不到的问题)

### 我做了什么 (What I did):
你遇到了 `exec /app/entrypoint.sh: no such file or directory` 的错误。这非常典型，具体原因是：
1. 上次更新中，我在构建 Docker 镜像时使用 `dos2unix` 修复了 `entrypoint.sh` 的换行符（从 Windows 的 CRLF 改为 Linux 的 LF）。
2. **但是**，在 `docker-compose.yml` 中，有一行配置 `volumes: - ./backend:/app`。这行配置的意思是：**在容器启动时，用你 Windows 电脑本地的 `./backend` 文件夹去覆盖容器里的 `/app` 文件夹。**
3. 因此，虽然镜像里的文件修好了，但容器一启动，你本地那个带有 Windows CRLF 换行符的错误文件又把修好的文件给覆盖了。Linux 看到 `#!/bin/bash\r` 时，会去寻找一个叫 `bash\r` 的解释器，找不到就会报 `no such file or directory`。

**修复方法**:
1. 修改了 `docker-compose.yml` 的 `entrypoint`，让它**在容器启动时（即文件被覆盖之后）**，动态执行一次 `dos2unix` 修复换行符，然后再执行脚本。
2. 增加了 `backend/.gitattributes` 文件，强制 Git 以后在下载 `.sh` 文件时必须保持 LF 换行符，双管齐下。

### 你需要做什么 (What you need to do):

这次更新修改了 `docker-compose.yml` 核心配置，请**严格按照以下步骤**执行：

1. **停止并清理现有环境**：
   ```bash
   docker-compose down -v
   ```

2. **拉取最新代码**：
   ```bash
   git pull
   ```

3. **重新构建并启动服务**：
   ```bash
   docker-compose up -d --build
   ```

4. **验证**：
   - 稍等 10 秒钟。
   - 访问 `http://localhost:8000/api/` 或 `http://localhost:8000/admin/`，现在应该可以正常显示了。
   - 访问 `http://localhost:3000/login`，输入账号 `admin` 密码 `admin123` 即可登录。

如果还有问题，请运行 `docker-compose logs backend` 并把输出发给我！
