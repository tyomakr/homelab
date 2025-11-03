homelab/
  .gitignore
  compose.yaml
  .env.example
  docs/
    README.md
    allowlist.example.yaml
  bin/
    acme-issue.sh
    deploy.sh
  config/
    traefik/
      static/
        traefik.yaml
      dynamic/
        00-middlewares.yaml
        01-allowlist.yaml         # ← реальный allowlist (НЕ класть в git)
        20-routers-remote.yaml
        90-tls-certs.yaml         # ← указывает на wildcard файлы
      acme-certs/                 # ← сюда acme.sh положит fullchain/privkey
      acme-home/                  # ← рабочая директория acme.sh (аккаунт, логи)
    nginx-splash/
      html/
        index.html
      conf.d/
        default.conf
  secrets/
    regru.env                     # ← единый файл секретов REG.RU (НЕ в git)
    basic_auth.htpasswd           # ← для dashboard (НЕ в git)
  data/
    gitea/                        # персистентные данные Gitea (НЕ в git)
