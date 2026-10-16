#!/bin/bash
# заглушка acme.sh: «выпускает» сертификат из тестового CA (setup_tls уже положил его в /var/lib/xray/cert)
case $1 in
  --list) ;;
  --issue) ;;
  --install-cert)
      while [ $# -gt 0 ]; do
        case $1 in
          --fullchain-file) cp /var/lib/xray/cert/fullchain.pem "$2"; shift ;;
          --key-file) cp /var/lib/xray/cert/privkey.pem "$2"; shift ;;
          --reloadcmd) reload=$2; shift ;;
        esac; shift
      done
      bash -c "$reload" ;;
esac
exit 0
