-----------------------------------------------------------------------------
-- |
-- Module      : Ministg.CallStack
-- Copyright   : (c) 2009 Bernie Pope 
-- License     : BSD-style
-- Maintainer  : bjpop@csse.unimelb.edu.au
-- Stability   : experimental
-- Portability : ghc
--
-- Stack of program annotations. Simulate a call stack.
-----------------------------------------------------------------------------

module Ministg.CallStack (CallStack, push, showCallStack, prettyCallStack) where

import Ministg.Pretty

type CallStack = [String]

push :: String -> CallStack -> CallStack
push = (:)

showCallStack :: CallStack -> String
showCallStack = unlines

prettyCallStack :: CallStack -> Doc
prettyCallStack [] = empty
prettyCallStack stack = char '<' <> hcat (punctuate (text "|") (map text stack)) <> char '>'
