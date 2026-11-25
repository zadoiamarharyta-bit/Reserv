# Backup Manager

A local Sinatra web application for scheduled ZIP backups and restores.

## Requirements

- Ruby 3.1 or newer
- Bundler

## Install and run

```bash
cd Reserv
bundle install
mkdir -p data public/css views
bundle exec rackup -o 127.0.0.1 -p 4567
```

Open <http://127.0.0.1:4567>.

Configuration and logs are saved under `data/config.json`, `data/backups.json`, and `data/logs.json`. JSON files are created automatically.

## Docker (optional)

There is no Docker configuration in this project, because host filesystem paths must be accessible to the Ruby process.
