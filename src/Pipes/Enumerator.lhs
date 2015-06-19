> module Pipes.Enumerator (
>   pipeToEnumerator
> ) where

> import Control.Monad.Trans.Class
> import qualified Pipes.Internal as P
> import qualified Data.Enumerator as E

  Connect a pipe to an iteratee, effectively converting it into an enumerator,
  generalised slightly to allow distinct input and output types. The chunks of
  the input stream are fed into the pipe one element at the time, and the pipe's
  output is fed to the iteratee one element per chunk. Once the input reaches
  @E.EOF@, the pipe is fed an infinite stream of @Nothing@ until it ends with
  a pure value. In effect, both the pipe and the iteratee are always consumed
  fully, with the resulting enumerator returning the results of both.

> pipeToEnumerator :: Monad m => P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
> pipeToEnumerator = advanceIteratee []


  State Machine 1
  ===============

  Advance a single iteratee step, keeping track of any input @cs@ that has been
  supplied by the upstream enumerator but not yet used. If the target iteratee blocks,
  we will supply it with input obtained by advancing source pipe; otherwise, we'll
  simply drain the pipe to completion, in order to retrieve the remainder of the
  upstream input and the pipe's return value:

> advanceIteratee :: Monad m => [a] -> P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
> advanceIteratee cs p (E.Continue ik)      = advancePipe cs ik p
> advanceIteratee cs p s                    = drainPipe cs s p

  Advance a pipe, feeding its response into a blocked iteratee @ik@.

> advancePipe :: Monad m => [a] -> (E.Stream b -> E.Iteratee b m r) -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
> advancePipe cs ik (P.Request _ pk)        = advancePipeWithChunks ik pk cs
> advancePipe cs ik (P.Respond x pk)        = ik (E.Chunks [x]) E.>>== advanceIteratee cs (pk ())
> advancePipe cs ik (P.M m)                 = lift m >>= advancePipe cs ik
> advancePipe cs ik (P.Pure q)              = ik (E.EOF) E.>>== finish q (E.Chunks cs)

> advancePipeWithChunks :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> [a] -> E.Iteratee a m (q, r)
> advancePipeWithChunks ik pk (c:cs)        = advancePipe cs ik (pk (Just c))
> advancePipeWithChunks ik pk []            = E.continue (advancePipeWithStream ik pk)

> advancePipeWithStream :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Stream a -> E.Iteratee a m (q, r)
> advancePipeWithStream ik pk (E.Chunks cs) = advancePipeWithChunks ik pk cs
> advancePipeWithStream ik pk (E.EOF)       = advancePipeWithEOF ik pk

> drainPipe :: Monad m => [a] -> E.Step b m r -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
> drainPipe cs s (P.Request _ pk)           = drainPipeWithChunks s pk cs
> drainPipe cs s (P.Respond _ pk)           = drainPipe cs s (pk ())
> drainPipe cs s (P.M m)                    = lift m >>= drainPipe cs s
> drainPipe cs s (P.Pure q)                 = finish q (E.Chunks cs) s

> drainPipeWithChunks :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> [a] -> E.Iteratee a m (q, r)
> drainPipeWithChunks s pk (c:cs)           = drainPipe cs s (pk (Just c))
> drainPipeWithChunks s pk []               = E.continue (drainPipeWithStream s pk)

> drainPipeWithStream :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Stream a -> E.Iteratee a m (q, r)
> drainPipeWithStream s pk (E.Chunks cs)    = drainPipeWithChunks s pk cs
> drainPipeWithStream s pk (E.EOF)          = drainPipeWithEOF s pk


  State Machine 2
  ===============

> advanceIteratee' :: Monad m => P.Proxy a' (Maybe a) () b m q -> E.Step b m r -> E.Iteratee a m (q, r)
> advanceIteratee' p (E.Continue ik)        = advancePipe' ik p
> advanceIteratee' p s                      = drainPipe' s p

> advancePipe' :: Monad m => (E.Stream b -> E.Iteratee b m r) -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
> advancePipe' ik (P.Request _ pk)          = advancePipeWithEOF ik pk
> advancePipe' ik (P.Respond x pk)          = ik (E.Chunks [x]) E.>>== advanceIteratee' (pk ())
> advancePipe' ik (P.M m)                   = lift m >>= advancePipe' ik
> advancePipe' ik (P.Pure q)                = ik (E.EOF) E.>>== finish q (E.EOF)

> advancePipeWithEOF :: Monad m => (E.Stream b -> E.Iteratee b m r) -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Iteratee a m (q, r)
> advancePipeWithEOF ik pk                  = advancePipe' ik (pk Nothing)

> drainPipe' :: Monad m => E.Step b m r -> P.Proxy a' (Maybe a) () b m q -> E.Iteratee a m (q, r)
> drainPipe' s (P.Request _ pk)             = drainPipeWithEOF s pk
> drainPipe' s (P.Respond _ pk)             = drainPipe' s (pk ())
> drainPipe' s (P.M m)                      = lift m >>= drainPipe' s
> drainPipe' s (P.Pure q)                   = finish q (E.EOF) s

> drainPipeWithEOF :: Monad m => E.Step b m r -> (Maybe a -> P.Proxy a' (Maybe a) () b m q) -> E.Iteratee a m (q, r)
> drainPipeWithEOF s pk                     = drainPipe' s (pk Nothing)


  Final Step
  ==========

> finish :: Monad m => q -> E.Stream a -> E.Step b m r -> E.Iteratee a m (q, r)
> finish q xs (E.Yield r _)                 = E.yield (q, r) xs
> finish _ _  (E.Error e)                   = E.throwError e
> finish _ _  (E.Continue _)                = error "divergent iteratee" -- iteratees aren't allowed to continue on EOF


  Data Type Reference
  ===================

    data Proxy a' a b' b m r
        = Request a' (a  -> Proxy a' a b' b m r )
        | Respond b  (b' -> Proxy a' a b' b m r )
        | M          (m    (Proxy a' a b' b m r))
        | Pure    r

    type Pipe a b = Proxy () a () b

    type Enumerator a m b = Step a m b -> Iteratee a m b

    data Step a m b =
        Continue (Stream a -> Iteratee a m b)
      | Yield b (Stream a)
      | Error SomeException

    newtype Iteratee a m b = Iteratee { runIteratee :: m (Step a m b) }

    data Stream a =
        Chunks [a]
      | EOF
