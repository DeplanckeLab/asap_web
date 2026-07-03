cd /srv/asap_run_new
docker build -t fabdavid/asap_run:v8.2 -f Dockerfile.v8.2 ./ 2>&1 > build.log
docker tag fabdavid/asap_run:v8.2 fabdavid/asap_run:latest
docker tag fabdavid/asap_run:v8.2 fabdavid/asap_run:v8
cd /srv/asap2_test
docker-compose build asap_run
