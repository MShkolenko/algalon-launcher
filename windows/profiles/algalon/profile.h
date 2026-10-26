// Realm profile for forever-launcher.cpp. Everything that names one realm lives here; the launcher code names none.
// Build with:  build.cmd algalon
// Algalon Forever (https://algaloncore.com), the realm the official release binaries are built for.
#pragma once

#define REALM_SERVER      L"algaloncore.com"   // host the hosts line points the portal name at (resolved at launch)
#define REALM_PORTAL      L"algalon"           // the client portal: algalon.actual.battle.net
#define REALM_CONFIG      L"Algalon.wtf"       // WTF\<config>, the launcher's own settings file; Config.wtf is untouched
#define REALM_NAME       L"Algalon"           // short name in messages
#define REALM_LONG_NAME  L"Algalon Forever"   // %LOCALAPPDATA% folder, hosts comment, CA name in messages
#define REALM_LONG_NAME_A "Algalon Forever"
#define REALM_ID          L"algalon"           // file and folder names: <id>-launcher, _forever_<id>_, hosts.bak-<id>-*
#define REALM_ID_A        "algalon"
#define REALM_MUTEX_ID    L"Algalon"           // Global\<id>LauncherHostsEdit, Local\<id>Launcher

// Algalon Forever CA, 2026-10-10..2036-10-07, nameConstraints permitted DNS:algalon.actual.battle.net (critical),
// SHA-1 9CD0509C3B0707141C4E04E93EE044DF9BF477CA. Public certificate only; its private key is kept offline.
#define REALM_CA_PEM \
    "-----BEGIN CERTIFICATE-----\n" \
    "MIIEXjCCAsagAwIBAgIUHOlA6lGRtKqq5+4T0t8VJEroNkcwDQYJKoZIhvcNAQEL\n" \
    "BQAwLzEQMA4GA1UECgwHQWxnYWxvbjEbMBkGA1UEAwwSQWxnYWxvbiBGb3JldmVy\n" \
    "IENBMB4XDTI2MTAxMDA4MDgwMVoXDTM2MTAwNzA4MDgwMVowLzEQMA4GA1UECgwH\n" \
    "QWxnYWxvbjEbMBkGA1UEAwwSQWxnYWxvbiBGb3JldmVyIENBMIIBojANBgkqhkiG\n" \
    "9w0BAQEFAAOCAY8AMIIBigKCAYEAjNgcD3xk392v2XSVvMDbArPZaADNzsMr72ny\n" \
    "1nQqYvVOLu6XUR+KOJbEgGhs7pJ/BuyPJdDRohSZv26r/RWaJDdLclWbC+DLHAVG\n" \
    "m2hEwRQSR5rI0Pp/vcOX9tgd01MKRzxowSQtcqmq/cMNu7EYJZUx66XjSjsVuKU9\n" \
    "/XFdR45csFw9kA1kQVbyq/+JzFb8VtNEjzIVqqFlkNWTQV9P5DBZwJFweG4ZeZPG\n" \
    "Y+JIkm3SgfgXpkSzYWWo+Jvqd4lyyfW4KWrz7aRU7dRKLuvxhaDUXz2rnHIHH1cW\n" \
    "r5EWNK1JOUDF+XKzcFhJXbTZa7ekLVwOsZWLplpFLTYW0RkQqFky2JkaSNCN81bR\n" \
    "+JxDeyzW6e9AloLgqVXI9j2XO6/xUMT0eMaGBO2SYICpskF5FbbX8op7ctsJfBji\n" \
    "ETzehJcUflexl/MrjJqWBbPWQx0nDrS9Nn/3T0M1lDDNkCi/15Yiiam8N+S4FOri\n" \
    "ZenaE2UvA7a/OQrL0F4sbIoT1T9HAgMBAAGjcjBwMBIGA1UdEwEB/wQIMAYBAf8C\n" \
    "AQAwDgYDVR0PAQH/BAQDAgEGMCsGA1UdHgEB/wQhMB+gHTAbghlhbGdhbG9uLmFj\n" \
    "dHVhbC5iYXR0bGUubmV0MB0GA1UdDgQWBBReRt7URM2/rugTTgIJxgpAi5mn9jAN\n" \
    "BgkqhkiG9w0BAQsFAAOCAYEATpQkjBA2lVVmOgITXawbk3hvMijgQx9TfewkEkd+\n" \
    "XW0m0YoqW5pqMRQkTJyfsrxIm5QESWcBbiZ+uUhD63P4+MaBlThA/OUhwcZQzXHU\n" \
    "npc41zMXlZ4aiJHUeaNqO6kiWwI8eUeIKMljBPu6rX1Fm0+sUfgdMrnZ8JQoNuhM\n" \
    "QIrmd9x1OuBIqKweA9CMqr75YDUD5TG+wcc8Gif/DKqACY+ib+BRW2pPYOozJH1l\n" \
    "rZjBqVwagQ3AW3Vf69JBGlCCUgSyrqWl1S8wQyBNdz9ry5/rGBEaTD4X+wFOv5/I\n" \
    "3W6GVwkZHdds2Pld+WsoKxBo7a2xcAjC0sy3VSLUtEpIDQV1Ym4MHPSy8oDHVsZ9\n" \
    "nlbsE5KsUxVlL/OGgG6MH2BLNMAh6vU3w1pVMS5rqSn1490RYTGU482lssmaDSS0\n" \
    "Oa/b076cW03FHX0Lk8UZ9xq3wJfh56rPupp2CaVTKCZNXvTaNV12moKRtv++vsLd\n" \
    "/aFCnS4Z+urSeYDTUjqsuhXm\n" \
    "-----END CERTIFICATE-----\n"

// Update feed (docs/update-feed.md): the latest full release of this repository, signed with the realm owner's ECDSA
// P-256 key. Public key, 64 bytes X||Y in hex; the private key is kept offline by the owner.
#define REALM_UPDATE_REPO   L"MShkolenko/algalon-launcher"
#define REALM_UPDATE_PUBKEY L"3AAF60D82A8FAF4433C49D51A7A01BE9CD62B39F3A3BBC452A7CC726E28675C2E44A00A9E54FA3A9E6AAA2560B4ABD6DDA487230CFB729C4A102D36AC1989D75"
