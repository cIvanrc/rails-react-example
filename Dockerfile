# I: Runtime Stage: ============================================================
# This is the stage where we build the runtime base image, which is used as the
# common ancestor by the rest of the stages, and contains the minimal runtime
# dependencies required for the application to run:

# Step 1: Use the official Ruby 2.6.3 Slim Strech image as base:
FROM ruby:2.6.5-slim-stretch AS runtime

# Step 2: We'll set the MALLOC_ARENA_MAX for optimization purposes & prevent memory bloat
# https://www.speedshop.co/2017/12/04/malloc-doubles-ruby-memory.html
ENV MALLOC_ARENA_MAX="2"

# Step 3: We'll set '/usr/src' path as the working directory:
# NOTE: This is a Linux "standard" practice - see:
# - http://www.pathname.com/fhs/2.2/
# - http://www.pathname.com/fhs/2.2/fhs-4.1.html
# - http://www.pathname.com/fhs/2.2/fhs-4.12.html

#RUN adduser -S $USER 
RUN useradd -g root -u 1000 username

WORKDIR /usr/src

# Step 4: We'll set the working dir as HOME and add the app's binaries path to
# $PATH:
ENV HOME=/usr/src PATH=/usr/src/bin:$PATH

# Step 5: We'll install curl for later dependencies installations
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl

# Step 6: Add nodejs source
RUN curl -sL https://deb.nodesource.com/setup_12.x | bash -

# Step 7: Add yarn packages repository
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list

# Step 8: Install the common runtime dependencies:
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    apt-transport-https software-properties-common \
    ca-certificates \
    libpq5 \
    openssl \
    nodejs \
    tzdata \
    yarn && \
    rm -rf /var/lib/apt/lists/*

# II: Development Stage: =======================================================
# In this stage we'll build the image used for development, including compilers,
# and development libraries. This is also a first step for building a releasable
# Docker image:

# Step 9: Start off from the "runtime" stage:
FROM runtime AS development

# Step 10: Install the development dependency packages with alpine package
# manager:
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    chromium \
    chromium-driver \
    git \
    libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Step 11: Fix npm uid-number error
# - see https://github.com/npm/uid-number/issues/7
RUN npm config set unsafe-perm true

# Step 12: Install the 'check-dependencies' node package:
RUN npm install -g check-dependencies


# Step 13: Copy the project's Gemfile + lock:
ADD Gemfile* /usr/src/

# Step 14: Install the current project gems - they can be safely changed later
# during development via `bundle install` or `bundle update`:
RUN bundle install --jobs=4 --retry=3

# Step 15: Set the default command:
CMD [ "rails", "server", "-b", "0.0.0.0" ]

# III: Testing stage: ==========================================================
# In this stage we'll add the current code from the project's source, so we can
# run tests with the code.
# Step 16: Start off from the development stage image:
FROM development AS testing

# Step 17: Copy the rest of the application code
ADD . /usr/src

# Step 18: Install Yarn packages:
RUN yarn install

# IV: Builder stage: ===========================================================
# In this stage we'll compile assets coming from the project's source, do some
# tests and cleanup. If the CI/CD that builds this image allows it, we should
# also run the app test suites here:

# Step 19: Start off from the development stage image:
FROM testing AS builder

# Step 20: Precompile assets:
RUN export DATABASE_URL=postgres://postgres@example.com:5432/fakedb \
    SECRET_KEY_BASE=10167c7f7654ed02b3557b05b88ece \
    RAILS_ENV=production && \
    rails assets:precompile && \
    rails webpacker:compile && \
    rails secret > /dev/null

# Step 21: Remove installed gems that belong to the development & test groups -
# we'll copy the remaining system gems into the deployable image on the next
# stage:
RUN bundle config without development:test && bundle clean

# Step 22: Remove files not used on release image:
RUN rm -rf \
    .rspec \
    Guardfile \
    bin/rspec \
    bin/checkdb \
    bin/dumpdb \
    bin/restoredb \
    bin/setup \
    bin/spring \
    bin/update \
    bin/dev-entrypoint.sh \
    config/spring.rb \
    node_modules \
    spec \
    config/initializers/listen_patch.rb \
    tmp/*

# V: Release stage: ============================================================
# In this stage, we build the final, deployable Docker image, which will be
# smaller than the images generated on previous stages:

# Step 23: Start off from the runtime stage image:
FROM runtime AS release

# Step 24: Copy the remaining installed gems from the "builder" stage:
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Step 25: Copy from app code from the "builder" stage, which at this point
# should have the assets from the asset pipeline already compiled:
COPY --from=builder /usr/src /usr/src

# Step 26: Set the RAILS/RACK_ENV and PORT default values:
ENV RAILS_ENV=production RACK_ENV=production PORT=3000

# Step 27: Generate the temporary directories in case they don't already exist:
RUN mkdir -p /usr/src/tmp/cache && \
    mkdir -p /usr/src/tmp/pids && \
    mkdir -p /usr/src/tmp/sockets && \
    chown -R nobody /usr/src

# Step 28: Set the container user to 'nobody':
USER nobody

# Step 29: Set the default command:
CMD [ "puma" ]

# Step 30 thru 34: Add label-schema.org labels to identify the build info:
ARG SOURCE_BRANCH="master"
ARG SOURCE_COMMIT="000000"
ARG IMAGE_NAME="rails-react-example:latest"

