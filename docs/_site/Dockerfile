FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/jekyll

ENV BUNDLE_PATH=/usr/local/bundle

CMD ["bash", "-c", "bundle install && bundle exec jekyll serve --host 0.0.0.0 --force_polling"]
