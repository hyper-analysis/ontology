{-# LANGUAGE ForeignFunctionInterface, JavaScriptFFI #-}
module Browser where

import GHC.Wasm.Prim (JSString(..), fromJSString, toJSString)
import Workbench.Runtime (runRequest)

foreign export javascript "workbench_run" workbenchRun :: JSString -> IO JSString

workbenchRun :: JSString -> IO JSString
workbenchRun = pure . toJSString . runRequest . fromJSString
