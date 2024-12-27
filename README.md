# batesste-homesetup

A repository of tools and applications I use to maintain my home IT
infrastructure.

# dyndns

The [dyndns](./dyndns) folder contains a simple bash script that I use
in combination with a tiny [Amazon Wed Services][ref-aws] EC2 instance
to track the IP address of my home router. I can use this to connect
to my main home server while I am travelling. From there I can jump to
any other machine in the system.

# Homebridge

The [homebridge](./homebridge) folder contains a docker-based setup
for [Homebridge][ref-homebridge] for my house. This allows me to use
[Apple HomeKit][ref-homekit] to communicate with all my home
automation devices. See [the README.md](./homebridge/README.md) for
more information.

[ref-aws]: https://aws.amazon.com/
[ref-homebridge]: https://homebridge.io/
