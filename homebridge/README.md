# My Homebridge Setup

[Homebridge][ref-homebridge] is an awesome application that connects
non-HomeKit devices to Apple's HomeKit (and hence the Apple Home app).

# Installing

You *can* do a Docker based install but for my setup I prefer to do
the ```apt``` based method. Instructions can be [found
here][ref-linux-install]. At some point I might add this to my
[batesste-ansible][ref-batesste-ansible] roles.

# Eufy Security Cameras

Add the [Eufy Plugin][ref-eufy-plugin] to Homebridge and then use
[these instructions][ref-eufy-instruct] to set up the Eufy security
cameras. My account details for both the main Eufy account and the
admin one I use for HomeBridge are in my Keeper Vault.

# Samsung Smart TV

Add the [Samsung Tizen Homebridge Plugin][ref-samsung-tizen] and
configure this as per [these instructions][ref-samsung-instruct]. You
also need to accept the API access on the TV.

[ref-homebridge]: https://homebridge.io/
[ref-linux-install]: https://github.com/homebridge/homebridge/wiki/Install-Homebridge-on-Debian-or-Ubuntu-Linux
[ref-batesste-ansible]: https://github.com/sbates130272/batesste-ansible
[ref-eufy-plugin]: https://github.com/homebridge-eufy-security/plugin
[ref-eufy-instruct]: https://github.com/homebridge-eufy-security/plugin/wiki/Create-a-dedicated-admin-account-for-Homebridge-Eufy-Security-Plugin
[ref-samsung-tizen]: https://github.com/tavicu/homebridge-samsung-tizen
[ref-samsung-instruct]: https://tavicu.github.io/homebridge-samsung-tizen/
