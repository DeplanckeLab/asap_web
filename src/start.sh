#!/bin/bash                                                                                                                                                                

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