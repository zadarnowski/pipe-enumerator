Pipes/Iteratees Bridge
======================

    Copyright © 2015 Patryk Zadarnowski «pat@jantar.org».
    All rights reserved.

This library defines a set of functions that convert between
the `Pipes` and `Data.Enumerator` paradigms. The conversion
is bidirectional: an appropriately-typed pipe can be converted
into an `Iteratee` and back into a pipe. In addition, a pipe
can be fed into an iteratee (or, more specifically, `Step`),
resulting in an `Enumerator`.

The library has been designed specifically for use with Snap,
but I'm sure that many other interesting uses of it exist.
