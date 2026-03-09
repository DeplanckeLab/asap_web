#!/bin/bash                                                                                                                                                                

# Start munged for SLURM authentication
# Paths are provided by environment to avoid hardcoded locations.
: "${MUNGE_BIN:?MUNGE_BIN is required}"
: "${MUNGE_SOCKET_PATH:?MUNGE_SOCKET_PATH is required}"
: "${MUNGE_KEY_PATH:?MUNGE_KEY_PATH is required}"
: "${MUNGE_RUNTIME_DIR:?MUNGE_RUNTIME_DIR is required}"
: "${MUNGE_LOG_DIR:?MUNGE_LOG_DIR is required}"
if [ -f "$MUNGE_BIN" ]; then
    # Check if we can access host munged socket
    if [ -S "$MUNGE_SOCKET_PATH" ]; then
        echo "Using host munged socket"
    else
        # Try to start our own munged if we have the key
        if [ -f "$MUNGE_KEY_PATH" ]; then
            mkdir -p "$MUNGE_RUNTIME_DIR" "$MUNGE_LOG_DIR"
            chmod 755 "$MUNGE_RUNTIME_DIR"
            chmod 700 "$MUNGE_LOG_DIR" 2>/dev/null || true
            # Try to copy key (may fail if no read permission)
            # If we're in munge group and key has group read, this might work
            cp "$MUNGE_KEY_PATH" "$MUNGE_RUNTIME_DIR/munge.key" 2>/dev/null || true
            if [ -f "$MUNGE_RUNTIME_DIR/munge.key" ]; then
                chmod 400 "$MUNGE_RUNTIME_DIR/munge.key" 2>/dev/null || true
                "$MUNGE_BIN" --force --num-threads=10 >/dev/null 2>&1 &
                sleep 2
            fi
        fi
    fi
fi

# Check if the Rails application already exists                                                                                                                            
if [ ! -f "Gemfile" ]; then
  echo "Rails application not found. Creating a new one..."
  # Replace "myapp" with your desired application name                                                                                                                     
  rails new . --force --database=postgresql --css tailwind #--javascript=esbuild --css tailwind                  
  echo "Rails application created."
else
  echo "Rails application already exists. Skipping creation step."
fi

rm -f ./tmp/pids/server.pid

bundle install

#RAILS_ENV=development /app/bin/delayed_job --pool=fast:10  start

#echo 'Start sunspot'
#bundle exec rake sunspot:solr:start

#echo 'Start puma in the background...'
#puma -C config/puma.rb > log/puma.log 2>&1 &

#echo 'Start rails exec_runs as a background task...'
#rails exec_runs --trace > log/exec_runs.log 2>&1 &

# Precompile assets                                                                                                                                                        
#bundle exec rails assets:precompile                                                                                                                                       

if [ "$RAILS_ENV" = "production" ]; then
    echo "Starting in production mode"
    bundle exec rails assets:precompile
    exec bundle exec rails server -b "0.0.0.0" -e production
else
    echo "Starting in development mode"
    exec ./bin/dev
fi