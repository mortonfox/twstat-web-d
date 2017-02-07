# twstat-web-d - Online Twitter stats generator

## Introduction

This is a [vibe.d](http://vibed.org/) website that provides a web interface for
[twstat-d](https://github.com/mortonfox/twstat-d). twstat-d is a D program that
generates a single web page of charts from data in a Twitter archive.

The generated web page references the following libraries from online sources:

* jQuery (from [CDNJS](http://cdnjs.com/))
* [jQCloud](https://github.com/lucaong/jQCloud) jQuery plugin (from [CDNJS](http://cdnjs.com/))
* [Google Chart Tools](https://developers.google.com/chart/)

### Twitter archive

In December 2012, Twitter
[introduced](http://blog.twitter.com/2012/12/your-twitter-archive.html) a
feature allowing users to download an archive of their entire user timeline. By
February 2013, it was available to all users.

To request your Twitter archive:

1. Visit <https://twitter.com/settings/account>
1. Click on the "Request your archive" button. (near the bottom of the settings page)
1. Wait for an email from Twitter with a download link.

## Installation

If you haven't done so already, install [DMD](http://dlang.org/download.html)
and [DUB](https://code.dlang.org/download).

Clone or download this git repository.

In the root folder, run the following:

```
dub build
./twstat-web-d
```

Then visit <http://127.0.0.1:8080/> in your web browser.

The default web server port is 8080. Use the ```-p``` option to change that.
For example:

```
./twstat-web-d -p 9000
```
