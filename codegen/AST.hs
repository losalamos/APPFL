{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}
module AST (
  Var,
  Con,
  Atom(..),
  Expr(..),
  Alt(..),
  Alts(..),
  Obj(..),
  Primop(..),
  BuiltinType(..),
  rmPrelude,
  primopTab,
  show,
  objListDoc,
) where

import PPrint
import Data.List (find, (\\))


{-  grammar

<var> :: C syntax, more or less

<con> :: start with uppercase

<lit> ::= int[eger]

<atom> ::= <lit> | <var>

<prog> ::= <def> (";" <def>)*

<obj> ::= "FUN" "(" <var>+ -> <expr> ")"
       |  "PAP" "(" <var> <atom>+ ")"
       |  "CON" "(" <con> <atom>* ")"
       |  "THUNK" <expr>
       |  "ERROR"  (aka BLACKHOLE)

<expr> ::= <atom>
       |  <var>"^"<arity> <atom>+
       |  <primop> <atom>+
       |  "let" "{" <defs> "}" "in" <expr>
       |  "case" <expr> "of" "{" <alts> "}"

<alts> ::= <alt> (";" <alt>)*

<alt> ::= <con> <var>* "->" <expr>
       |  <var> "->" <expr>

<arity> ::= <pos> | "_"

-}

-- not really the place for this, maybe need to factor
-- the common types into a module
data BuiltinType = UBInt
                 | UBDouble             
                   deriving (Eq,Show,Ord)           

type Var = String
type Con = String

data Atom = Var  Var
          | LitI Int
          | LitB Bool
          | LitF Float
          | LitD Double
          | LitC Char
            deriving(Eq)

instance Show Atom where
    show (Var v) = v
    show (LitI i) = show i
    show (LitB False) = "false#"
    show (LitB True) = "true#"
    show (LitF f) = show f ++ "(f)"
    show (LitD d) = show d ++ "(d)"
    show (LitC c) = [c]

data Obj a = FUN   {omd :: a, vs :: [Var],   e :: Expr a , oname :: String}
           | PAP   {omd :: a, f  :: Var,     as :: [Atom], oname :: String}
           | CON   {omd :: a, c  :: Con,     as :: [Atom], oname :: String}
           | THUNK {omd :: a, e  :: Expr a               , oname :: String}
           | BLACKHOLE {omd :: a                         , oname :: String}
             deriving(Eq,Show)

-- 7.9 EFCalls (and EPrimops, for consistency) changed to accept Expr args.
-- Parser (and other traversals) should enforce use of *only* EAtom as args
data Expr a = EAtom   {emd :: a,                    ea :: Atom}
            | EFCall  {emd :: a, ev :: Var,         eas :: [Expr a]}
            | EPrimop {emd :: a, eprimop :: Primop, eas :: [Expr a]}
            | ELet    {emd :: a, edefs :: [Obj a],  ee :: Expr a}
            | ECase   {emd :: a, ee :: Expr a,      ealts :: Alts a}
              deriving(Eq,Show)

data Alts a = Alts {altsmd :: a, alts :: [Alt a], aname :: String}
              deriving(Eq,Show)

data Alt a = ACon {amd :: a, ac :: Con, avs :: [Var], ae :: Expr a}
           | ADef {amd :: a,            av :: Var,    ae :: Expr a}
             deriving(Eq,Show)

-- when calculating free variables we need an enclosing environment that
-- includes the known primops.  This will allow proper scoping.  As such
-- we initially parse EPrimops as EFCalls, then transform and check saturation
-- here.  We only need to distinguish EPrimop from EFCall because special
-- code is generated for them.

data Primop = Piadd -- Int -> Int -> Int
            | Pisub 
            | Pimul
            | Pidiv
            | Pimod
            | Pimax
            | Pimin

            | Pieq -- Int -> Int -> Bool
            | Pine
            | Pilt
            | Pile
            | Pigt
            | Pige

            | Pineg -- Int -> Int

            -- the following are deprecated
            | PintToBool
              deriving(Eq,Show)

-- these are the C names, not STG names
primopTab = 
    [("iplus_h",  Piadd), 
     ("isub_h",   Pisub),
     ("imul_h",   Pimul),
     ("idiv_h",   Pidiv),
     ("imod_h",   Pimod),
    
     ("ieq_h",    Pieq),
     ("ine_h",    Pine),
     ("ilt_h",    Pilt),
     ("ile_h",    Pile),
     ("igt_h",    Pigt),
     ("ige_h",    Pige),

     ("ineg_h",   Pineg),

     ("imin_h",   Pimax),
     ("imax_h",   Pimin),

     -- the following are deprecated
     ("intToBool_h", PintToBool)
    ]


preludeObjNames =
  ["error",
   "unit",
   "nil",
   "zero",
   "one",
   "two",
   "three",
   "four",
   "five",
   "six",
   "seven",
   "eight",
   "nine",
   "ten",
   "false",
   "true",
   "eqInt",
   "multInt",
   "plusInt",
   "subInt",
   "append",
   "const",
   "apply",
   "map",
   "head",
   "tail",
   "foldl",
   "sum",
   "zipWith",
   "seq",
   "forcelist",
   "take"]


-- functions for removing some or all standard Prelude objects from the 
-- list of objects in a parsed STG program.  Useful for debugging.
rmPrelude :: [Obj a] -> [Obj a]
rmPrelude = rmPreludeLess []
rmPreludeLess :: [Var] -> [Obj a] -> [Obj a]
rmPreludeLess keeps =
  let objs = preludeObjNames \\ keeps
  in filter (not . (`elem` objs) . oname)

stgPrimName p =
  case find ((==p).snd) primopTab of
   Nothing -> error $ "primop lookup failed for " ++ show p
   Just x -> reverse ('#' : (drop 2 $ reverse $ fst x))
     
instance Unparse Atom where
  unparse (Var v)  = text v
  unparse (LitI i) = int i
  unparse (LitF f) = float f
  unparse x        = text $ show x -- not expecting other literals yet


instance Unparse Primop where
  unparse = text.stgPrimName 

instance Unparse a => Unparse (Alt a) where
  unparse ACon{amd, ac, avs, ae} =
    unparse amd $+$
    text ac <+> (hsep $ map text avs) <+> arw <+> unparse ae

  unparse ADef{amd, av, ae} =
    unparse amd $+$
    text av <+> arw <+> unparse ae

instance Unparse a => Unparse (Alts a) where
  unparse Alts{altsmd, alts} = -- Note aname field is *not* in use here
    unparse altsmd $+$
    (vcat $ punctuate semi $ map unparse alts)

instance Unparse a => Unparse (Expr a) where
  unparse EAtom{emd, ea} =
    unparse emd $+$
    unparse ea

  unparse EFCall{emd, ev, eas} =
    unparse emd $+$
    text ev <+> (hsep $ map unparse eas)

  unparse EPrimop{emd, eprimop, eas} =
    unparse emd $+$
    unparse eprimop <+> (hsep $ map unparse eas)

  unparse ELet{emd, edefs, ee} =
    unparse emd $+$
    text "let" <+> lbrace $+$
    (nest 2 $ vcat $ punctuate semi $ map unparse edefs) <> rbrace $+$
    text "in" <+> unparse ee

  unparse ECase{emd, ee, ealts} =
    unparse emd $+$
    text "case" <+> unparse ee <+> text "of" <+> lbrace $+$
    (nest 2 $ unparse ealts) <> rbrace


instance Unparse a => Unparse (Obj a) where
  unparse FUN{omd, vs, e, oname} =
    unparse omd $+$
    text oname <+> equals <+> text "FUN" <>
    parens ((hsep $ map text vs) <+> arw $+$ nest ident (unparse e))
    where ident = length vs + (sum $ map length vs) -- aligns expr with arrow

  unparse PAP{omd, f, as, oname} =
    unparse omd $+$
    text oname <+> equals <+> text "PAP" <>
    parens (text f <+> (hsep $ map unparse as))

  unparse CON{omd, c, as, oname} =
    unparse omd $+$
    text oname <+> equals <+> text "CON" <>
    parens (text c <+> (hsep $ map unparse as))

  unparse THUNK{omd, e, oname} =
    unparse omd $+$
    text oname <+> equals <+> text "THUNK" <>
    parens (unparse e)

  unparse BLACKHOLE{omd, oname} =
    unparse omd $+$
    text oname <+> equals <+> text "ERROR"


-- () metadata = empty document
-- empty is the identity Doc for the associative pretty printing operators
instance Unparse () where
  unparse () = empty


instance PPrint BuiltinType where
  pprint b = case b of
    UBInt -> text "UBInt"
    UBDouble -> text "UBDouble"
    
 


objListDoc :: (PPrint a) => [Obj a] -> Doc
objListDoc objs = vcat $ map pprint objs

instance (PPrint a) => PPrint (Obj a) where
  pprint o = case o of
    FUN{..} -> braces
               (text "FUN:" $+$
                nest 2
                (text "name:" <+> text oname $+$
                 text "vars:" <+> listText vs $+$                        
                 text "metadata:" $+$
                 nest 2 (pprint omd) $+$
                 text "expr:" $+$
                 nest 2 (pprint e)
                )
               )
    PAP{..} -> braces 
               (text "PAP:" $+$
                nest 2
                (text "name:" <+> text oname $+$
                 text "function:" <+> text f $+$
                 text "args:" <+> brackList (map pprint as) $+$
                 text "metadata:" $+$
                 nest 2 (pprint omd)
                )
               )
    CON{..} -> braces
               (text "CON:" $+$
                nest 2
                (text "name:" <+> text oname $+$
                 text "datacon:" <+> text c $+$
                 text "args:" <+> brackList (map pprint as) $+$
                 text "metadata:" $+$
                 nest 2 (pprint omd)
                )
               )
    THUNK{..} -> braces
                 (text "THUNK:" $+$
                  nest 2
                  (text "name:" <+> text oname $+$
                   text "metadata:" $+$
                   nest 2 (pprint omd) $+$
                   text "expression:" $+$
                   nest 2 (pprint e)
                  )
                 )
    BLACKHOLE{..} -> braces
                     (text "BLACKHOLE" $+$
                      nest 2
                      (text "name:" <+> text oname $+$
                       text "metadata:" $+$
                       nest 2 (pprint omd)
                      )
                     )
instance (PPrint a) => PPrint (Expr a) where
  pprint e = case e of
    EAtom{..} -> braces
                 (text "EAtom:" $+$
                  nest 2
                  (text "atom:" <+> pprint ea $+$
                   text "metadata:" $+$
                   nest 2 (pprint emd)
                  )
                 )
    EFCall{..} -> braces
                  (text "EFCall:" $+$
                   nest 2
                   (text "function:" <+> text ev $+$
                    -- 7.9 changed, grab atoms from eas (same in primop below)
                    text "args:" <+> (brackets $ vcat $ punctuate comma $ map pprint eas) $+$ 
                    text "metadata:" $+$
                    nest 2 (pprint emd)
                   )
                  )
    EPrimop{..} -> braces
                   (text "EPrimop:" $+$
                    nest 2
                    (text "primop:" <+> pprint eprimop $+$
                     text "args:" <+> (brackets $ vcat $ punctuate comma $ map pprint eas) $+$
                     text "metadata" $+$
                     nest 2 (pprint emd)
                    )
                   )
    ELet{..} -> braces
                (text "ELet:" $+$
                 nest 2
                 (text "metadata:" $+$
                  nest 2 (pprint emd) $+$
                  text "definitions:" $+$
                  nest 2 (objListDoc edefs) $+$
                  text "expression:" $+$
                  nest 2 (pprint ee)
                 )
                )
    ECase{..} -> braces
                 (text "ECase:" $+$
                  nest 2
                  (text "metadata:" $+$
                   nest 2 (pprint emd) $+$
                   text "scrutinee:" $+$
                   nest 2 (pprint ee) $+$
                   text "alts:" $+$
                   nest 2 (pprint ealts)
                  )
                 )

instance (PPrint a) => PPrint (Alts a) where
  pprint Alts{..} = braces
                    (text "Alts:" $+$
                     nest 2
                     (text "name:" <+> text aname $+$
                      text "metadata:" $+$ 
                      nest 2 (pprint altsmd) $+$
                      text "alt defs:" $+$
                      nest 2 (vcat (map pprint alts))
                     )
                    )
instance (PPrint a) => PPrint (Alt a) where  
  pprint a = case a of
    ACon{..} -> braces
                (text "ACon:" $+$
                 nest 2
                 (text "datacon:" <+> text ac $+$
                  text "vars:" <+> listText avs $+$
                  text "metadata:" $+$
                  nest 2 (pprint amd) $+$
                  text "expression:" $+$
                  nest 2 (pprint ae)
                 )
                )
    ADef{..} -> braces
                (text "ADef:" $+$
                 nest 2
                 (text "var:" <+> text av $+$
                  text "metadata:" $+$
                  nest 2 (pprint amd) $+$
                  text "expression:" $+$
                  nest 2 (pprint ae)
                 )
                )
              
instance PPrint Atom where
  pprint = unparse

instance PPrint Primop where
  pprint = unparse
