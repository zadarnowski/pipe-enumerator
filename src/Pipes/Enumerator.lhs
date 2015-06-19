> -- | Module:    Pipes.Enumerator
> -- Description: A bidirectional bridge between pipes and iteratees
> -- Copyright:   © 2015 Patryk Zadarnowski <pat@jantar.org>
> -- License:     BSD3
> -- Maintainer:  pat@jantar.org
> -- Stability:   experimental
> -- Portability: portable
> --
> -- This module defines a set of functions that convert between
> -- the "Pipes" and "Data.Enumerator" paradigms. The conversion
> -- is bidirectional: an appropriately-typed pipe can be converted
> -- into an 'E.Iteratee' and back into a pipe. In addition, a pipe
> -- can be fed into an iteratee (or, more specifically, 'E.Step'),
> -- resulting in an 'E.Enumerator'.
> --
> -- The library has been designed specifically for use with "Snap",
> -- but I'm sure that many other interesting uses of it exist.

> module Pipes.Enumerator (
>   fromStream, toStream, toSingletonStream,
>   iterateeToPipe, stepToPipe,
>   pipeToIteratee,
>   pipeToEnumerator
> ) where

> import Control.Exception (SomeException)
> import Control.Monad.Trans.Class
> import qualified Pipes.Internal as P
> import qualified Data.Enumerator as E


  Data Type Reference
  ===================

  Definitions of the relevant Pipe and Iteratee types, for reference:

    data P.Proxy a' a b' b m r
        = P.Request a' (a  -> P.Proxy a' a b' b m r )
        | P.Respond b  (b' -> P.Proxy a' a b' b m r )
        | P.M          (m    (P.Proxy a' a b' b m r))
        | P.Pure    r

    type P.Pipe a b = P.Proxy () a () b

    type E.Enumerator a m b = E.Step a m b -> E.Iteratee a m b

    data E.Step a m b =
        E.Continue (E.Stream a -> E.Iteratee a m b)
      | E.Yield b (E.Stream a)
      | E.Error SomeException

    newtype E.Iteratee a m b = E.Iteratee { E.runIteratee :: m (E.Step a m b) }

    data E.Stream a =
        E.Chunks [a]
      | E.EOF

> -- | Converts a 'E.Stream' to an optional list.
> fromStream :: E.Stream a -> Maybe [a]
> fromStream (E.Chunks cs) = Just cs
> fromStream (E.EOF)       = Nothing

> -- | Converts an optional list to a 'E.Stream'.
> toStream :: Maybe [a] -> E.Stream a
> toStream (Just cs) = E.Chunks cs
> toStream (Nothing) = E.EOF

> -- | Converts an optional value to a singleton 'E.Stream'.
> toSingletonStream :: Maybe a -> E.Stream a
> toSingletonStream (Just c)  = E.Chunks [c]
> toSingletonStream (Nothing) = E.EOF

> -- | Converts an 'E.Iteratee' into a 'P.Consumer'.
> iterateeToPipe :: Monad m => E.Iteratee a m r -> P.Proxy () (Maybe a) b' b m (Either SomeException (r, Maybe [a]))
> iterateeToPipe = P.M . fmap stepToPipe . E.runIteratee

> -- | Converts a 'E.Step' into a 'P.Consumer'.
> stepToPipe :: Monad m => E.Step a m r -> P.Proxy () (Maybe a) b' b m (Either SomeException (r, Maybe [a]))
> stepToPipe (E.Continue ik) = P.Request () (P.M . fmap stepToPipe . E.runIteratee . ik . toSingletonStream)
> stepToPipe (E.Yield r xs)  = return (Right (r, fromStream xs))
> stepToPipe (E.Error e)     = return (Left e)

> -- | Converts a 'P.Pipe' into an 'E.Iteratee'.
> --   Any output of the pipe is quietly discarded.
> pipeToIteratee :: Monad m => P.Proxy a' (Maybe a) () b m r -> E.Iteratee a m r
> pipeToIteratee = convert1 []
>  where
>   convert1 cs (P.Request _ pk)    = convert2 pk cs
>   convert1 cs (P.Respond _ pk)    = convert1 cs (pk ())
>   convert1 cs (P.M m)             = lift m >>= convert1 cs
>   convert1 cs (P.Pure r)          = E.yield r (E.Chunks cs)
>   convert2 pk (c:cs)              = convert1 cs (pk (Just c))
>   convert2 pk []                  = E.continue (convert3 pk)
>   convert3 pk (E.Chunks cs)       = convert2 pk cs
>   convert3 pk (E.EOF)             = convert4 pk
>   convert4 pk                     = convert5 (pk Nothing)
>   convert5 (P.Request _ pk)       = convert4 pk
>   convert5 (P.Respond _ pk)       = convert5 (pk ())
>   convert5 (P.M m)                = lift m >>= convert5
>   convert5 (P.Pure r)             = E.yield r E.EOF

> -- | Feed the output of a 'P.Pipe' to a 'E.Step', effectively converting it into
> --   an 'E.Enumerator',  generalised slightly to allow distinct input and output
> --   types.  The chunks of the input stream are fed into the pipe one element at
> --   the time, and the pipe's  output is fed to the iteratee one element per chunk.
> --   Once the input reaches 'E.EOF', the pipe is fed an infinite stream of 'Nothing'
> --   until it ends with  a pure value. In effect, both the pipe and the iteratee are
> --   always consumed fully, with the resulting enumerator returning the results of both.
> pipeToEnumerator :: Monad m => P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
> pipeToEnumerator = advanceIteratee []
>  where

>   advanceIteratee :: Monad m => [a] -> P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
>   advanceIteratee cs p (E.Continue ik)      = advancePipe cs ik p
>   advanceIteratee cs p s                    = drainPipe cs s p

>   advanceIteratee' :: Monad m => P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
>   advanceIteratee' p (E.Continue ik)        = advancePipe' ik p
>   advanceIteratee' p s                      = drainPipe' s p

>   advancePipe :: Monad m => [a] -> (E.Stream b -> E.Iteratee b m r) -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
>   advancePipe cs ik (P.Request _ pk)        = advancePipeWithChunks ik pk cs
>   advancePipe cs ik (P.Respond x pk)        = ik (E.Chunks [x]) E.>>== advanceIteratee cs (pk ())
>   advancePipe cs ik (P.M m)                 = lift m >>= advancePipe cs ik
>   advancePipe cs ik (P.Pure q)              = ik (E.EOF) E.>>== finish q (E.Chunks cs)

>   advancePipe' :: Monad m => (E.Stream b -> E.Iteratee b m r) -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
>   advancePipe' ik (P.Request _ pk)          = advancePipeWithEOF ik pk
>   advancePipe' ik (P.Respond x pk)          = ik (E.Chunks [x]) E.>>== advanceIteratee' (pk ())
>   advancePipe' ik (P.M m)                   = lift m >>= advancePipe' ik
>   advancePipe' ik (P.Pure q)                = ik (E.EOF) E.>>== finish q (E.EOF)

>   advancePipeWithStream :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Stream a -> E.Iteratee a m (q, r)
>   advancePipeWithStream ik pk (E.Chunks cs) = advancePipeWithChunks ik pk cs
>   advancePipeWithStream ik pk (E.EOF)       = advancePipeWithEOF ik pk

>   advancePipeWithChunks :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> [a] -> E.Iteratee a m (q, r)
>   advancePipeWithChunks ik pk (c:cs)        = advancePipe cs ik (pk (Just c))
>   advancePipeWithChunks ik pk []            = E.continue (advancePipeWithStream ik pk)

>   advancePipeWithEOF :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Iteratee a m (q, r)
>   advancePipeWithEOF ik pk                  = advancePipe' ik (pk Nothing)

>   drainPipe :: Monad m => [a] -> E.Step b m r -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
>   drainPipe cs s (P.Request _ pk)           = drainPipeWithChunks s pk cs
>   drainPipe cs s (P.Respond _ pk)           = drainPipe cs s (pk ())
>   drainPipe cs s (P.M m)                    = lift m >>= drainPipe cs s
>   drainPipe cs s (P.Pure q)                 = finish q (E.Chunks cs) s

>   drainPipe' :: Monad m => E.Step b m r -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
>   drainPipe' s (P.Request _ pk)             = drainPipeWithEOF s pk
>   drainPipe' s (P.Respond _ pk)             = drainPipe' s (pk ())
>   drainPipe' s (P.M m)                      = lift m >>= drainPipe' s
>   drainPipe' s (P.Pure q)                   = finish q (E.EOF) s

>   drainPipeWithStream :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Stream a -> E.Iteratee a m (q, r)
>   drainPipeWithStream s pk (E.Chunks cs)    = drainPipeWithChunks s pk cs
>   drainPipeWithStream s pk (E.EOF)          = drainPipeWithEOF s pk

>   drainPipeWithChunks :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> [a] -> E.Iteratee a m (q, r)
>   drainPipeWithChunks s pk (c:cs)           = drainPipe cs s (pk (Just c))
>   drainPipeWithChunks s pk []               = E.continue (drainPipeWithStream s pk)

>   drainPipeWithEOF :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Iteratee a m (q, r)
>   drainPipeWithEOF s pk                     = drainPipe' s (pk Nothing)

>   finish :: Monad m => q -> E.Stream a -> E.Step b m r -> E.Iteratee a m (q, r)
>   finish q xs (E.Yield r _)                 = E.yield (q, r) xs
>   finish _ _  (E.Error e)                   = E.throwError e
>   finish _ _  (E.Continue _)                = error "divergent iteratee" -- iteratees aren't allowed to continue on EOF

