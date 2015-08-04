{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE TupleSections         #-}

module InfoTab(
  InfoTab(..),
  setCMaps,
  setITs,
  showITs,
  showITType,
  showObjType
) where

import Prelude
import PPrint
import AST
import ADT
import CMap
import Data.List(nub,(\\))

import Data.Map (Map)
import qualified Data.Map as Map

import Data.Set (Set)
import qualified Data.Set as Set


-- need an infoTab entry for each lexically distinct HO or SHO

-- *****************************************************

{-
  every Expr, Alt, Obj has metadata, e.g. name, freevars
-}

data InfoTab = 
    Fun { 
      typ :: Monotype,
      ctyp :: Polytype,
      name :: String,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      entryCode :: String,
      arity :: Int}      
  | Pap { 
      typ :: Monotype,
      ctyp :: Polytype,
      name :: String,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      entryCode :: String,
      args     :: [Atom],
      knownCall :: Maybe InfoTab} -- of the FUN
  | Con { 
      typ :: Monotype,
      ctyp :: Polytype,
      name :: String,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      entryCode :: String,
      args :: [Atom],
      arity :: Int,
      con :: String, -- actual constructor name, not object name
      cmap :: CMap }
  | Thunk { 
      typ :: Monotype,
      ctyp :: Polytype,
      name :: String,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      entryCode :: String }
  | Blackhole {
      typ :: Monotype,
      ctyp :: Polytype,
      name :: String,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      entryCode :: String }
  | ITAtom { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      noHeapAlloc :: Bool }
  | ITFCall { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      noHeapAlloc :: Bool,
      knownCall :: Maybe InfoTab } -- of the FUN
  | ITPrimop { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)], 
      truefvs :: [Var],
      noHeapAlloc :: Bool }
  | ITLet { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      noHeapAlloc :: Bool }
  | ITCase { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      noHeapAlloc :: Bool,
      cmap :: CMap}
  | ITAlt { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      cmap :: CMap }
  | ITAlts { 
      typ :: Monotype,
      ctyp :: Polytype,
      fvs :: [(Var,Monotype)],
      truefvs :: [Var],
      name :: String,         -- for C infotab
      entryCode :: String }   -- for C infotab
  -- the following may be useful later
  -- for now case continuation is handled by Alts.ITAlts
  -- similarly function continuation could be handled by EFCall.ITFCall
  -- update continuation by THUNK.Thunk?
  -- call continuation by ???
  | ITUpdcont
  | ITCasecont
  | ITCallcont 
  | ITFuncont
    deriving(Eq)   

class ITsOf a b where 
    itsOf :: a -> b

instance ITsOf a [b] => ITsOf [a] [b] where
   itsOf = concatMap itsOf

instance ITsOf (Obj a) [a] where
    itsOf FUN{omd, e} = omd : itsOf e
    itsOf THUNK{omd, e}  = omd : itsOf e
    itsOf o = [omd o] -- PAP, CON, BLACKHOLE

instance ITsOf (Expr a) [a] where
    itsOf ELet{emd, edefs, ee}  = emd : (itsOf edefs) ++ (itsOf ee)
    itsOf ECase{emd, ee, ealts} = emd : (itsOf ee) ++ (itsOf ealts)
    itsOf e = [emd e] -- EAtom, EFCall, EPrimop

instance ITsOf (Alt a) [a] where
    itsOf ACon{amd, ae} = amd : itsOf ae
    itsOf ADef{amd, ae} = amd : itsOf ae
    
instance ITsOf (Alts a) [a] where
    itsOf Alts{altsmd, alts} = altsmd : itsOf alts

-- ****************************************************************

-- typUndef = error "typ set undefined in InfoTab.hs"
-- ctypUndef = error "ctyp set undefined in InfoTab.hs"
typUndef = MPhony
ctypUndef = PPoly [] MPhony


class SetITs a b where 
    setITs :: a -> b

instance SetITs [Obj ([Var],[Var])] [Obj InfoTab] where
    setITs = map setITs

instance SetITs (Expr ([Var],[Var])) (Expr InfoTab) where
    setITs e@(ELet emd defs ee) = 
        ELet (makeIT e) (setITs defs) (setITs ee)

    setITs e@(ECase emd ee alts) = 
        ECase (makeIT e) (setITs ee) (setITs alts)

    setITs e@(EAtom emd a) = 
        EAtom (makeIT e) a

    setITs e@(EFCall emd f eas) =
        EFCall (makeIT e) f $ map setITs eas

    setITs e@(EPrimop emd p eas) =
        EPrimop (makeIT e) p $ map setITs eas 

instance SetITs (Alts ([Var],[Var])) (Alts InfoTab) where
    setITs as@(Alts altsmd alts name) = 
       Alts (makeIT as) (map setITs alts) name

instance SetITs (Alt ([Var],[Var])) (Alt InfoTab) where
    setITs a@(ACon amd c vs e) = 
        ACon (makeIT a) c vs (setITs e)
    setITs a@(ADef amd v e) = 
        ADef (makeIT a) v (setITs e)

instance SetITs (Obj ([Var],[Var])) (Obj InfoTab) where
    setITs o@(FUN omd vs e n) = 
        FUN (makeIT o) vs (setITs e) n

    setITs o@(PAP omd f as n) = 
        PAP (makeIT o) f as n

    setITs o@(CON omd c as n) = 
        CON (makeIT o) c as n

    setITs o@(THUNK omd e n) = 
        THUNK (makeIT o) (setITs e) n

    setITs o@(BLACKHOLE omd n) = 
        BLACKHOLE (makeIT o) n


-- ****************************************************************

class MakeIT a where
    makeIT :: a -> InfoTab

instance MakeIT (Obj ([Var],[Var])) where
    makeIT o@(FUN (fvs,truefvs) vs e n) = 
        Fun { arity = length vs,
              name = n,
              fvs = zip fvs $ repeat typUndef,
              truefvs = truefvs,
              typ = typUndef,
              ctyp = ctypUndef,
    --          entryCode = showITType o ++ "_" ++ n
              entryCode = "fun_" ++ n
            }

    makeIT o@(PAP (fvs,truefvs) f as n) =
        Pap { args = as,
              name = n,
              fvs = zip fvs $ repeat typUndef,
              truefvs = truefvs,
              typ = typUndef,
              ctyp = ctypUndef,
    --          entryCode = showITType o ++ "_" ++ n
              entryCode = "fun_" ++ f,
              knownCall = Nothing
            }

    makeIT o@(CON (fvs,truefvs) c as n) =
        Con { con = c,
              arity = length as,
              args = as,
              name = n,
              fvs = zip fvs $ repeat typUndef,
              truefvs = truefvs,
              typ = typUndef,
              ctyp = ctypUndef,
    --          entryCode = showITType o ++ "_" ++ n
              entryCode = "stg_constructorcall",
              cmap = error "ADef cmap undefined"
            }

    makeIT o@(THUNK (fvs,truefvs) e n) =
        Thunk { name = n,
                fvs = zip fvs $ repeat typUndef,
                truefvs = truefvs,
                typ = typUndef,
                ctyp = ctypUndef,
    --            entryCode = showITType o ++ "_" ++ n
                entryCode = "fun_" ++ n
              }

    makeIT o@(BLACKHOLE (fvs,truefvs) n) =
        Blackhole { name = n,
                    typ = typUndef,
                    ctyp = ctypUndef,
                    fvs = zip fvs $ repeat typUndef,
                    truefvs = truefvs,
    --                entryCode = showITType o ++ "_" ++ n
                    entryCode = "stg_error"
                  }

instance MakeIT (Expr ([Var],[Var])) where
    makeIT ELet{emd = (fvs,truefvs)} = 
        ITLet {fvs = zip fvs $ repeat typUndef, 
               truefvs = truefvs, 
               typ = typUndef, 
               ctyp = ctypUndef, 
               noHeapAlloc = False}

    makeIT ECase{emd = (fvs,truefvs)} = 
        ITCase{fvs = zip fvs $ repeat typUndef, 
               truefvs = truefvs, 
               typ = typUndef, 
               ctyp = ctypUndef,
               noHeapAlloc = False,
               cmap = Map.empty}

    makeIT EAtom{emd = (fvs,truefvs)} = 
        ITAtom{fvs = zip fvs $ repeat typUndef, 
               truefvs = truefvs, 
               typ = typUndef, 
               ctyp = ctypUndef, 
               noHeapAlloc = False}

    makeIT EFCall{emd = (fvs,truefvs)} = 
        ITFCall{fvs = zip fvs $ repeat typUndef, 
                truefvs = truefvs, 
                typ = typUndef, 
                ctyp = ctypUndef, 
                noHeapAlloc = False, 
                knownCall = Nothing}

    makeIT EPrimop{emd = (fvs,truefvs)} = 
        ITPrimop{fvs = zip fvs $ repeat typUndef, 
                 truefvs = truefvs, 
                 typ = typUndef, 
                 ctyp = ctypUndef, 
                 noHeapAlloc = False}

instance MakeIT (Alts ([Var],[Var])) where
    makeIT Alts{altsmd = (fvs,truefvs), aname} = 
        ITAlts {fvs = zip fvs $ repeat typUndef, 
                truefvs = truefvs, 
                typ = typUndef,
                ctyp = ctypUndef,
                entryCode = aname,
                name = aname}

instance MakeIT (Alt ([Var],[Var])) where
    makeIT ACon{amd = (fvs,truefvs)} = 
        ITAlt{fvs = zip fvs $ repeat typUndef, 
              truefvs = truefvs, 
              typ = typUndef,
              ctyp = ctypUndef,
              cmap = Map.empty}

    makeIT ADef{amd = (fvs,truefvs)} = 
        ITAlt{fvs = zip fvs $ repeat typUndef, 
              truefvs = truefvs, 
              typ = typUndef,
              ctyp = ctypUndef,
              cmap = error "ADef cmap set undefined in InfoTab.hs"}


showObjType Fun {} = "FUN"
showObjType Pap {} = "PAP"
showObjType Con {} = "CON"
showObjType Thunk {} = "THUNK"
showObjType Blackhole {} = "BLACKHOLE"
showObjType _ = error "bad ObjType"

showITType _ = "sho"
-- showITType FUN {} = "ofun"
-- showITType PAP {} = "opap"
-- showITType CON {} = "ocon"
-- showITType THUNK {} = "otnk"
-- showITType BLACKHOLE {} = "obhl"
-- showITTType _ = error "bad ITType"

showITs os = concatMap showIT $ itsOf os

{-
  char name[32];  // for debugging
  int fvCount;    // lexically determined, should be in layout
  CmmFnPtr entryCode; 
  ObjType objType; // kind of object, tag for union
  LayoutInfo layout;
  ...
-}

showIT it@(Fun {}) =
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = FUN,\n" ++
    "    .layoutInfo.payloadSize = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .funFields.arity     = " ++ show (arity it) ++ ",\n" ++
    "  };\n"
        
showIT it@(Pap {}) =
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = PAP,\n" ++
    -- payloadSize handled specially for PAP
    "    .layoutInfo.payloadSize = " ++ show (length $ fvs it) ++ ",\n" ++
    "  };\n"
        
showIT it@(Con {}) =
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = CON,\n" ++
    "    .layoutInfo.payloadSize = " ++ show (arity it) ++ ",\n" ++
    "    .conFields.arity     = " ++ show (arity it) ++ ",\n" ++
    "    .conFields.tag       = " ++ luConTag (con it) (cmap it) ++ ",\n" ++
    "    .conFields.conName   = " ++ show (con it) ++ ",\n" ++
    "  };\n"
        
showIT it@(Thunk {}) =
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = THUNK,\n" ++
    "    .layoutInfo.payloadSize = " ++ show (max 1 (length $ fvs it)) ++ ",\n" ++
    "  };\n"
        
showIT it@(Blackhole {}) = 
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = BLACKHOLE,\n" ++
    "    .layoutInfo.payloadSize = 0,\n" ++ 
    "  };\n"

showIT it@(ITAlts{}) =
    "InfoTab it_" ++ name it ++ " = \n" ++
    "  { .name                = " ++ show (name it) ++ ",\n" ++
    "    .fvCount             = " ++ show (length $ fvs it) ++ ",\n" ++
    "    .entryCode           = &" ++ entryCode it ++ ",\n" ++
    "    .objType             = CASECONT,\n" ++
    "    .layoutInfo.payloadSize = " ++ show (length $ fvs it) ++ ",\n" ++
    "  };\n"

showIT _ = ""

      
-- MODIFIED 6.30 - David ----------------------------------------
-- code below replaces code from ConMaps.hs to set the CMaps in
-- CON and ACon infotabs for typechecker and codegen lookups


setCMaps :: ([TyCon], [Obj InfoTab]) -> ([TyCon], [Obj InfoTab])
setCMaps (tycons, objs) =
  let cmap = toCMap tycons
  in (tycons, addCMapToITs cmap objs)

addCMapToITs :: CMap -> [Obj InfoTab] -> [Obj InfoTab]
addCMapToITs cmap objs =  map (setITs . (cmap,)) objs


instance SetITs (CMap,(Obj InfoTab)) (Obj InfoTab) where
  setITs (cmap,obj) = case obj of

    o@FUN{e} ->
      o{ e = setITs (cmap,e) }

    o@THUNK{e} ->
      o{ e = setITs (cmap,e) }

    o@CON{omd, c} ->
      o{omd = omd{ cmap = cmap } }

    o -> o --  BLACKHOLE and PAP don't need modification

instance SetITs (CMap, (Expr InfoTab)) (Expr InfoTab) where
  setITs (cmap,expr) = case expr of

    e@ECase{ee, ealts, emd} ->
      e{ ee    = setITs (cmap,ee),
         ealts = setITs (cmap,ealts),
         emd   = emd { cmap = cmap } }

    e@ELet{ee, edefs} ->
      e{ ee    = setITs (cmap,ee),
         edefs = map (setITs . (cmap,)) edefs }
      
    e -> e -- EAtom, EFCall, EPrimop don't need modification

instance SetITs (CMap, (Alts InfoTab)) (Alts InfoTab) where
  setITs (cmap,a@Alts{alts}) =
    a{ alts = map (setITs . (cmap,)) alts}
    
instance SetITs (CMap, (Alt InfoTab)) (Alt InfoTab) where
  setITs (cmap, alt) = case alt of

    a@ACon{amd, ac, ae} ->
      a{ amd = amd{cmap = cmap},
         ae = setITs (cmap,ae) }

    a@ADef{ae} ->
      a { ae = setITs (cmap,ae) }

instance PPrint InfoTab where
 pprint it = text "Infotab:" <+> itName $+$
            nest 2 (
              text "typ:" <+> pprint (typ it) $+$
              itExtras )
   where
     makeName n = text "name:" <+> text n
     makeKCDoc kc = case kc of
       Just it' -> text "known call to" <+> text (name it')
       Nothing  -> text "unknown call"
     makeHADoc nha = text "noHeapAlloc:" <+> boolean nha
     freevsDoc vs = text "fvs:" <+> listText (map fst vs) -- should show Monotype, too
     trufreevsDoc vs = text "truefvs:" <+> listText vs
     frvarsDoc vs tvs = freevsDoc vs $+$ trufreevsDoc tvs
     (itName, itExtras) =
           case it of
             Fun{..} ->
               (text "Fun", makeName name $+$
                            frvarsDoc fvs truefvs)
             Pap{..} ->
               (text "Pap", makeName name $+$
                            makeKCDoc knownCall $+$
                            frvarsDoc fvs truefvs)
             Con{..} ->
               (text "Con", makeName name $+$
                            frvarsDoc fvs truefvs)
             Thunk{..} ->
               (text "Thunk", makeName name $+$
                              frvarsDoc fvs truefvs)
             Blackhole{..} ->
               (text "Blackhole", makeName name $+$
                                  frvarsDoc fvs truefvs)
             ITAtom{..} ->
               (text "ITAtom", makeHADoc noHeapAlloc $+$
                               frvarsDoc fvs truefvs)
             ITFCall{..} ->
               (text "ITFCall", makeHADoc noHeapAlloc $+$
                                makeKCDoc knownCall $+$
                                frvarsDoc fvs truefvs)
             ITPrimop{..} ->
               (text "ITPrimop", makeHADoc noHeapAlloc $+$
                                 frvarsDoc fvs truefvs)
             ITLet{..} ->
               (text "ITLet", makeHADoc noHeapAlloc $+$
                              frvarsDoc fvs truefvs)
             ITCase{..} ->
               (text "ITCase", makeHADoc noHeapAlloc $+$
                               frvarsDoc fvs truefvs)
             ITAlt{..} ->
               (text "ITAlt", frvarsDoc fvs truefvs)
             ITAlts{..} ->
               (text "ITAlts", makeName name $+$
                               frvarsDoc fvs truefvs)
             _ -> (text "Other InfoTab",empty)
  
