# batesste-homesetup

A repository of tools and applications I use to maintain my home IT
infrastructure.

# dyndns

The [dyndns](./dyndns) folder contains a simple bash script that I use
in combination with an [AWS S3][ref-aws-s3] object to track the IP
address of my home router. I can use this to connect to my main home
server while I am travelling. From there I can jump to any other
machine in the system. See [the README.md](./dyndns/README.md) for
more information.

# Homebridge

The [homebridge](./homebridge) folder contains a docker-based setup
for [Homebridge][ref-homebridge] for my house. This allows me to use
[Apple HomeKit][ref-homekit] to communicate with all my home
automation devices. See [the README.md](./homebridge/README.md) for
more information.

# SSL Certificate

In order to connect to http-based services inside my home setup I want
to deploy [SSL certificates][ref-ssl-certs] that have been
authenticated. There is an easy command line way to do this based on
[this tutorial][ref-ssl-tutorial] that uses
[certbot][ref-certbot]. This tutorial is so good I won't both
repeating the steps here. Just refer to it and you should be good,
though you do want to make sure you run the command for my homelab
domain:
```
$ sudo certbot certonly --manual --preferred-challenges dns -d "*.homelab.raithlin.com"
```

Note that we do need to create a TXT based DNS record on my domain
manager who is currently [GoDaddy][ref-godaddy].

# Grafana and Prometheus

These are used for monitoring my home network and, in time, other
things. Grafana is installed from their apt repository and Prometheus
is installed from the Ubuntu repository. Setup is pretty
straight-forward so I do not go into details here.

However it is worth noting that on systems with WiFi we do want to
enable the WiFi collector. We can do this by adding the following to
an override file.
```
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter $ARGS --collector.wifi
```
Note that unfortunately this collector is not available for macOS and
so this won't work on Mac-based systems.

Note that in order to gather more data we alter the retention default
policy in Prometheus. In Ubuntu we do this via adding the following to
the ```/etc/default/prometheus``` file and then restart the Prometheus
systemd service.
```
# Set the command-line arguments to pass to the server.
# Due to shell escaping, to pass backslashes for regexes, you need to double
# them (\\d for \d). If running under systemd, you need to double them again
# (\\\\d to mean \d), and escape newlines too.
ARGS="--storage.tsdb.retention.size=10GB"
```

# Firefly III

I use [Firefly III][ref-firefly] for personal finance tracking. I have
a [GitHub repo][ref-batesste-ff] dedicated to this. Best refer to that
repo for more information.

# Home Internet Speedtest

In order to ensure my WAN connection is stable I run a speedtest using
[this container][ref-speedtest] and then integrate the metrics into my
Prometheus and Grafana servers. Using something like this:
```
docker run -d --restart=always \
  -p 9469:9469 \
  billimek/prometheus-speedtest-exporter:latest
```
See the referenced project for an example of the Prometheus scrape
config and the Grafana dashboard.

# Backups

We enable a full disk backup of servers to AWS S3 buckets using
[mountpoint][ref-mountpoint] and a systemd service. See the
[backup README.md](./backup/README.md) for more information.

# Time Machine

In order to backup my MacBook we use [this timemachine
repo][ref-time-machine] on the home server. In order to get this
started and in order to provide AWS S3 backup of the volume that
contains the time machine data use the [docker
compose](./time-machine/batesste-time-machine.yml) file.

Place a ```.aws.creds.env``` file in the ```time-machine``` folder of
the form:
```bash
AWS_ACCESS_KEY_ID="<my AWS id>"
AWS_SECRET_ACCESS_KEY="<my AWS secret>
```
Then install using something like (only once ever):
```bash
cd time-machine
docker volume create batesste-time-machine
docker compose -f batesste-time-machine.dc.yml -d up
```
Note that since we are not broadcasting you will need to establish a
link to the server via the instructions in main repo.

[ref-aws-s3]: https://aws.amazon.com/s3/
[ref-homebridge]: https://homebridge.io/
[ref-ssl-certs]: https://www.kaspersky.com/resource-center/definitions/what-is-a-ssl-certificate
[ref-ssl-tutorial]: https://ongkhaiwei.medium.com/generate-lets-encrypt-certificate-with-dns-challenge-and-namecheap-e5999a040708
[ref-certbot]: https://eff-certbot.readthedocs.io/en/latest/index.html
[ref-godaddy]: https://godaddy.com/
[ref-firefly]: https://docs.firefly-iii.org/
[ref-batesste-ff]:https://github.com/sbates130272/batesste-firefly-iii
[ref-speedtest]:https://github.com/billimek/prometheus-speedtest-exporter
[ref-mountpoint]: https://github.com/awslabs/mountpoint-s3
[ref-time-machine]: https://github.com/mbentley/docker-timemachine
