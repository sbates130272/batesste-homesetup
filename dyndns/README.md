# batesste-s3-dyndns

A simple systemd and bash based method for tracking the WAN IP address
allocated to my home network.

## Overview

This simple framework runs a bash script every 15 minutes to compare
my currently allocated AWN IPv4 address with the one stored in a S3
bucket on my AWS account. If they differ we update the object in the
S3 bucket.

Using this I can always ascertain my home-network WAN IPv4 address and
obtain remote access.

## Installation

Copy my AWS credentials into a file in this folder called
```batesste-s3-dyndns.secrets``` and ensure it is of the form:
```
UPDATE=yes
AWS_KEY=<my AWS key>
AWS_SECRET=<my AWS secret>
```
Then proceed with the following steps:
1. ```sudo cp batesste-s3-dyndns /usr/local/bin```.
1. ```sudo cp batesste-s3-dyndns.service /etc/systemd/system/```.
1. ```sudo cp batesste-s3-dyndns.timer /etc/systemd/system/```.
1. ```sudo mkdir -p /usr/local/share/batesste-s3-dyndns```.
1. ```sudo mv batesste-s3-dyndns.secrets /usr/local/share/batesste-s3-dyndns/```.
1. ```sudo systemctl daemon-reload```
1. ```sudo systemctl enable batesste-s3-dyndns.timer```
1. ```sudo systemctl start batesste-s3-dyndns.timer```
