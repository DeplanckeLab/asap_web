#!/bin/bash                                                                                                                                                                

# Start munged for SLURM authentication
# Note: munge.key is mounted read-only from host, owned by munge:munge with 400 permissions
# Since we're running as rvmuser (in munge group), we can't read it directly
# We'll use the host's munged socket instead, or copy the key if we have root access
# For now, try to use the host munged socket via the mounted volume
if [ -f /usr/sbin/munged ]; then
    # Check if we can access host munged socket
    if [ -S /run/munge/munge.socket.2 ]; then
        echo "Using host munged socket"
    else
        # Try to start our own munged if we have the key
        if [ -f /etc/munge/munge.key ]; then
            mkdir -p /run/munge /var/log/munge
            chmod 755 /run/munge
            chmod 700 /var/log/munge 2>/dev/null || true
            # Try to copy key (may fail if no read permission)
            # If we're in munge group and key has group read, this might work
            cp /etc/munge/munge.key /run/munge/munge.key 2>/dev/null || true
            if [ -f /run/munge/munge.key ]; then
                chmod 400 /run/munge/munge.key 2>/dev/null || true
                /usr/sbin/munged --force --num-threads=10 >/dev/null 2>&1 &
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

# Start Rails server                                                                                                                                                       
#bundle exec rails server -b "0.0.0.0"                                                                                                                                     
#if [ "$RAILS_ENV" = "production" ]; then
#    echo "RAILS_ENV is production"
#    bin/rails importmap:cache
#    bundle exec rails assets:precompile
#    RAILS_ENV=production bundle exec rails server
#else
#    echo "RAILS_ENV is not production"
#    #    ./bin/dev && fg
#    
#fi

#./bin/thrust ./bin/rails server -b "0.0.0.0"
#./bin/dev
#nohup bin/rails tailwindcss:watch > log/tailwind.log 2>&1 &
#./bin/rails server -b '0.0.0.0' & 
#./bin/rails tailwindcss:watch &
./bin/dev