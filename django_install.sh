#!/bin/bash
echo "==1== INICIANDO === "
sudo ln -svf /usr/bin/python3 /usr/bin/python

echo "==2== Actualizando el Sistema === "
sudo apt-get -qq update
sudo apt-get -qq upgrade

echo "==3== Instalamos las dependencia para usar PostgreSQL con Python/Django: === "
sudo apt-get -qq install build-essential libpq-dev python-dev

echo "==4== Instalamos PostgreSQL Server: === "
sudo apt-get -qq install postgresql postgresql-contrib

echo "==5== Instalamos Nginx: === "
sudo apt-get -qq install nginx

echo "==6== Instalamos Supervisor: === "
sudo apt-get -qq install supervisor

echo "==7== Iniciamos Supervisor: === "
sudo systemctl enable supervisor
sudo systemctl start supervisor

echo "==8== Instalamos python3-venv: === "
sudo apt-get -qq install python3-venv

echo "==9== Configuramos PostgreSQL: === "
sudo su - postgres -c "createuser -s django"
sudo su - postgres -c "createdb django_prod --owner django"
sudo -u postgres psql -c "ALTER USER django WITH PASSWORD 'django'"

# Creamos el usuario del sistema
sudo adduser --system --quiet --shell=/bin/bash --home=/home/django --gecos 'django' --group django
sudo gpasswd -a django sudo

echo "==10== Creamos el entorno virtual === "
sudo -u django python3 -m venv /home/django/.venv

echo "==11== Instalamos Django en el entorno virtual === "
sudo -u django /home/django/.venv/bin/pip install -q Django

echo "==12== Clonamos el proyecto === "
read -p 'Indique la dirección del repo a clonar (https://github.com/falconsoft3d/django-father): ' gitrepo
sudo -u django git -C /home/django clone $gitrepo
read -p 'Indique la el nombre de la carpeta del proyecto (django-father): ' project
read -p 'Indique el nombre de la app principal de Django (father): ' djapp

echo "==13== Instalamos las dependencias === "
sudo -u django /home/django/.venv/bin/pip install -q -r /home/django/$project/requirements.txt

echo "==14== Instalamos Gunicorn === "
sudo -u django /home/django/.venv/bin/pip install -q gunicorn

sudo -u django bash -c 'cat > /home/django/.venv/bin/gunicorn_start' <<EOF
#!/bin/bash

NAME="django_app"
DIR=/home/django/$project
USER=django
GROUP=django
WORKERS=3
BIND=unix:/home/django/gunicorn.sock
DJANGO_SETTINGS_MODULE=$djapp.settings
DJANGO_WSGI_MODULE=$djapp.wsgi
LOG_LEVEL=error

source /home/django/.venv/bin/activate

export DJANGO_SETTINGS_MODULE=\$DJANGO_SETTINGS_MODULE
export PYTHONPATH=\$DIR:\$PYTHONPATH

exec /home/django/.venv/bin/gunicorn \${DJANGO_WSGI_MODULE}:application \
  --name \$NAME \
  --workers \$WORKERS \
  --user=\$USER \
  --group=\$GROUP \
  --bind=\$BIND \
  --log-level=\$LOG_LEVEL \
  --log-file=-
EOF

sudo chmod u+x /home/django/.venv/bin/gunicorn_start

echo "==15== Convertimos a Ejecutable el Fichero: gunicorn_start === "
chmod u+x /home/django/.venv/bin/gunicorn_start

echo "==16== Configurando Supervisor === "
sudo -u django mkdir -p /home/django/logs
sudo -u django touch /home/django/logs/gunicorn-error.log

sudo tee /etc/supervisor/conf.d/django_app.conf > /dev/null <<EOF
[program:django_app]
command=/home/django/.venv/bin/gunicorn_start
user=django
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/home/django/logs/gunicorn-error.log
EOF

sudo supervisorctl reread
sudo supervisorctl update

echo "==17== Configurando Nginx ==="
sudo tee /etc/nginx/sites-available/django_app > /dev/null <<EOF
upstream django_app {
    server unix:/home/django/gunicorn.sock fail_timeout=0;
}

server {
    listen 80;

    # add here the ip address of your server
    # or a domain pointing to that ip (like example.com or www.example.com)
    server_name $serverip;

    keepalive_timeout 5;
    client_max_body_size 4G;

    access_log /home/django/logs/nginx-access.log;
    error_log /home/django/logs/nginx-error.log;

    location /static/ {
        alias /home/django/static/;
    }

    # checks for static file, if not found proxy to app
    location / {
        try_files \$uri @proxy_to_app;
    }

    location @proxy_to_app {
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header Host \$http_host;
      proxy_redirect off;
      proxy_pass http://django_app;
    }
}
EOF

# Le metemos la IP al settings al final
sudo tee /home/django/$project/$djapp/localsettings.py > /dev/null <<EOF
from .settings import ALLOWED_HOSTS
ALLOWED_HOSTS += ["$serverip"]
STATIC_ROOT = "/home/django/static/"
EOF

sudo ln -sf /etc/nginx/sites-available/django_app /etc/nginx/sites-enabled/django_app
sudo rm -f /etc/nginx/sites-enabled/default
sudo service nginx restart

echo "=== Finalizando ==="
sudo -u django /home/django/.venv/bin/python /home/django/$project/manage.py migrate
sudo -u django /home/django/.venv/bin/python /home/django/$project/manage.py collectstatic --noinput
sudo chown django:django /home/django/ -R
sudo chown django:django /home/django/.venv/ -R
sudo supervisorctl restart django_app
