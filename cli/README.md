# lr

`lr` is the command line program for interacting with LayerRail.

# Building

With `make`:

```
$ make
```

Directly with `go build`:

```
$ go build -ldflags "-s -w -X main.version=`cat version.txt`" -tags osusergo,netgo
```

# Running

First, make sure `LR_TOKEN` in the environment is set to your LayerRail personal
access token. Then run it:

```
$ lr
```

# License

AGPL
