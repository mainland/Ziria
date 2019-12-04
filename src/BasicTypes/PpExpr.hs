{-
   Copyright (c) Microsoft Corporation
   All rights reserved.

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
{-# OPTIONS_GHC -Wall -fno-warn-orphans -fno-warn-name-shadowing #-}
{-# LANGUAGE FlexibleInstances #-}
-- | Pretty-printing type classes instances
module PpExpr (nestingDepth, ppName, ppNameUniq, ppEs, ppBind) where

import Prelude hiding ((<>))
import Text.PrettyPrint.HughesPJ

import AstExpr
import Outputable

nestingDepth :: Int
nestingDepth = 2

{-------------------------------------------------------------------------------
  Outputable instances
-------------------------------------------------------------------------------}

instance Outputable ty => Outputable (GUnOp ty) where
  ppr op = case op of
    NatExp  -> text "exp"
    Neg     -> text "-"
    Not     -> text "not"
    BwNeg   -> text "~"
    Cast ty -> ppr ty
    ALength -> text "length"

instance Outputable BinOp where
  ppr op = case op of
    Add   -> text "+"
    Sub   -> text "-"
    Mult  -> text "*"
    Div   -> text "/"
    Rem   -> text "%"
    Expon -> text "**"

    ShL   -> text "<<"
    ShR   -> text ">>"
    BwAnd -> text "&"
    BwOr  -> text "|"
    BwXor -> text "^"

    Eq    -> text "=="
    Neq   -> text "!="
    Lt    -> text "<"
    Gt    -> text ">"
    Leq   -> text "<="
    Geq   -> text ">="
    And   -> text "&&"
    Or    -> text "||"

instance Outputable Val where
  ppr v = case v of
    VBit b           -> text $ if b then "'1" else "'0"
    VInt n Signed    -> integer n
    VInt n Unsigned  -> integer n <> text "u"    
    VDouble d        -> double d
    VBool b          -> if b then text "true" else text "false"
    VString s        -> text s
    VUnit            -> text "tt"

instance Outputable ForceInline where
  ppr ForceInline = brackets $ text "ForceInline"
  ppr NoInline    = brackets $ text "NoInline"
  ppr AutoInline  = text ""

instance Outputable ty => Outputable (GExp0 ty a) where
  ppr e = case e of
    EVal _ v        -> ppr v
    EValArr v       -> text "{" <> pprArr v <> text "}"
    EVar x          -> ppName x
    EUnOp op e      -> ppr op <> parens (ppr e)
    EBinOp op e1 e2 -> ppr e1 <> ppr op <> ppr e2
    EAssign e1 e2   -> ppr e1 <+> text ":=" <+> text "-- (easgn)" $$
                       nest 2 (ppr e2)

    EArrRead earr eix LISingleton  -> ppr earr <> brackets (ppr eix)
    EArrRead earr eix (LILength n) -> ppr earr <> brackets ((ppr eix) <> text ":+" <> int n)
    EArrRead earr eix (LIMeta   x) -> ppr earr <> brackets ((ppr eix) <> text ":+" <> text  x)

    EArrWrite earr eix LISingleton eval ->
      ppr earr <> (brackets (ppr eix)) <+> text ":=" <+> text "-- (earrwrite) " $$
      nest 2 (ppr eval)

    EArrWrite earr eix (LILength r) eval ->
      ppr earr <> (brackets $ (ppr eix) <> text ":+" <> int r) <+> text ":=" <+> text "-- (earrwrite) " $$
      nest 2 (ppr eval)

    EArrWrite earr eix (LIMeta x) eval ->
      ppr earr <> assign ":=" (brackets $ (ppr eix) <> text ":+" <> text x) (ppr eval)

    EFor ui ix estart elen ebody ->
      ppr ui <+>
       (text "for" <+>
         ppr ix <+> text "in" <+> brackets (ppr estart <> comma <+> ppr elen) <+> text "{" $$
         nest nestingDepth (ppr ebody) $$
         text "}"
       )

    EWhile econd ebody ->
      text "while" <+> parens (ppr econd) <+> text "{" $$
      nest nestingDepth (ppr ebody) $$
      text "}"

    ELet x fi e1 e2 ->
      text "let" <> ppr fi <+> ppBind x <+> text "=" $$
      nest 2 (ppr e1) $$
      text "in" $$
      ppr e2

    ELetRef x Nothing e2 ->
      text "var" <+> ppBind x <+> text "in" $$
      ppr e2

    ELetRef x (Just e1) e2 ->
      text "var" <+> assign ":=" (ppBind x) (ppr e1) <+> text "in" $$
      ppr e2

    ESeq e1 e2       -> ppr e1 <> semi $$ ppr e2
    ECall f eargs    -> ppr f <> parens (ppEs ppr comma eargs)
    EIf be e1 e2     -> text "if" <+> ppr be <+> text "{" $$
                          nest nestingDepth (ppr e1) $$
                        text "}" <+> text "else" <+> text "{" $$
                          nest nestingDepth (ppr e2) $$
                        text "}"
    EPrint True e1s   -> text "println" <+> ppEs ppr comma e1s
    EPrint False e1s  -> text "print"   <+> ppEs ppr comma e1s
    EError _ str     -> text "error " <+> text str
    ELUT _ e1        -> text "LUT" <+> ppr e1
    EProj e fn       -> ppr e <> text "." <> text fn

    EStruct t tfs ->
      let ppfe (fn,fe) = text fn <+> text "=" <+> ppr fe
      in ppr t <+> braces (hsep (punctuate comma (map ppfe tfs)))

    where assign s e1 e2 = e1 <+> text s <+> e2

instance Outputable UnrollInfo where
  ppr Unroll     = text "unroll"
  ppr NoUnroll   = text "nounroll"
  ppr AutoUnroll = empty

instance Outputable ty => Outputable (GExp ty a) where
  ppr = ppr . unExp

instance Outputable (GStructDef ty) where
  -- TODO: Perhaps it would make more sense to show the entire thing
  ppr (StructDef nm _) = text nm


instance Outputable ty => Outputable (GFun ty a) where
  ppr fn = case unFun fn of
    MkFunDefined f params ebody ->
      ppName f <> parens (ppParams params) <+> text "=" $$
          nest nestingDepth (ppr ebody)
    MkFunExternal f params ty ->
      text (name f) <> parens (ppParams params) <+> text ":" <+> ppr ty


{-------------------------------------------------------------------------------
  Utility

  Many of these are used in the Comp pretty-printer too.
-------------------------------------------------------------------------------}

pprArr :: Outputable ty => [GExp ty a] -> Doc
pprArr (h:[]) = ppr h
pprArr (h:t)  = ppr h <> comma <+> pprArr t
pprArr []     = empty

ppEs :: (a -> Doc) -> Doc -> [a] -> Doc
ppEs f sep eargs = case eargs of
    []         -> empty
    e : []     -> f e
    e : eargs' -> f e <> sep <+> ppEs f sep eargs'

ppBind :: Outputable ty => GName ty -> Doc
ppBind nm = ppName nm <+> colon <+> ppr (nameTyp nm)

ppParams :: Outputable ty => [GName ty] -> Doc
ppParams params =
  case params of
    []          -> empty
    x : []      -> ppMut (nameMut x) <> ppBind x 
    x : params' -> ppMut (nameMut x) <> ppBind x <> comma <+> ppParams params'

ppMut :: MutKind -> Doc
ppMut Imm = empty
ppMut Mut = text "var " 

{-------------------------------------------------------------------------------
  Show instances
-------------------------------------------------------------------------------}

instance Show (NumExpr) where show = render . ppr
instance Show Ty        where show = render . ppr
instance Show (GStructDef ty) where show = render . ppr

instance Outputable ty => Show (GFun ty a)  where show = render . ppr
instance Outputable ty => Show (GUnOp ty)   where show = render . ppr
instance Outputable ty => Show (GExp0 ty a) where show = render . ppr
instance Outputable ty => Show (GExp ty a)  where show = render . ppr

