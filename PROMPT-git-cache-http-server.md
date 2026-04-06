## Project: Kazo-ca/git-cache-http-server

Wrap the npm package `git-cache-http-server` (from https://github.com/jonasmalacofilho/git-cache-http-server) into a Docker image and auto-publish it to Docker Hub as `kazoca2/git-cache-http-server`.

---

### 1. Dockerfile

Create a `Dockerfile` based on `node:22-alpine` that:
- Installs `git` (required dependency)
- Installs `git-cache-http-server` globally via npm
- Exposes port `8080`
- Uses a volume at `/var/cache/git` for the cache directory
- Runs `git-cache-http-server --port 8080 --cache-dir /var/cache/git` as entrypoint
- Runs as a non-root user for security

### 2. GitHub Actions Workflow

Create `.github/workflows/docker-publish.yml` that:
- Triggers on:
  - Push to `main` branch
  - Tags matching `v*` (e.g. `v1.0.0`)
  - Weekly schedule (to pick up base image security updates)
- Uses `docker/login-action` to authenticate to Docker Hub
- Uses `docker/build-push-action` to build and push
- Tags the image as:
  - `kazoca2/git-cache-http-server:latest` (on main push)
  - `kazoca2/git-cache-http-server:<tag>` (on version tags, e.g. `v1.0.0`)
  - `kazoca2/git-cache-http-server:sha-<short-sha>` (always)
- Uses Docker layer caching via `docker/setup-buildx-action` and GitHub Actions cache
- Repository secrets needed: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`

### 3. README.md

Create a `README.md` with:
- Project description: Docker image wrapping `git-cache-http-server` for easy deployment
- Quick start: `docker run -d -p 8080:8080 -v git_cache:/var/cache/git kazoca2/git-cache-http-server`
- Usage with docker-compose example
- Usage with git config: `git config --global url."http://your-cache:8080/".insteadOf https://`
- Credit to the upstream project: https://github.com/jonasmalacofilho/git-cache-http-server
- Link to Docker Hub: https://hub.docker.com/r/kazoca2/git-cache-http-server

### 4. .dockerignore

Create a `.dockerignore` with:
```
.git
.github
README.md
LICENSE
```

### 5. LICENSE

Use MIT license, matching the upstream project.

---

### Docker Hub Secrets Setup Reminder

After creating the repo, add these GitHub repository secrets:
- `DOCKERHUB_USERNAME` = `kazoca2`
- `DOCKERHUB_TOKEN` = (Docker Hub access token from https://hub.docker.com/settings/security)
