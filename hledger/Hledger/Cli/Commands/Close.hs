{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiWayIf #-}

module Hledger.Cli.Commands.Close (
  closemode
 ,close
)
where

import Control.Monad (when)
import Data.Function (on)
import Data.List (groupBy)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Calendar (addDays)
import Lens.Micro ((^.))
import System.Console.CmdArgs.Explicit as C

import Hledger
import Hledger.Cli.CliOptions

defretaindesc = "retain earnings"
defclosedesc  = "closing balances"
defopendesc   = "opening balances"
defretainacct = "equity:retained earnings"
defcloseacct  = "equity:opening/closing balances"

closemode = hledgerCommandMode
  $(embedFileRelative "Hledger/Cli/Commands/Close.txt")
  [flagNone ["close"]        (setboolopt "close")   "show a closing transaction (default)"
  ,flagNone ["open"]         (setboolopt "open")    "show an opening transaction"
  ,flagNone ["migrate"]      (setboolopt "migrate") "show both closing and opening transactions"
  ,flagNone ["assert"]       (setboolopt "assert")  "show closing balance assertions"
  ,flagNone ["assign"]       (setboolopt "assign")  "show opening balance assignments (an alternative to closing/opening transactions)"
  ,flagNone ["retain"]       (setboolopt "retain")  "show a retain earnings transaction (for RX accounts)"
  ,flagNone ["explicit","x"] (setboolopt "explicit") "show all amounts explicitly"
  ,flagNone ["show-costs"]   (setboolopt "show-costs") "show amounts with different costs separately"
  ,flagNone ["interleaved"]  (setboolopt "interleaved") "show source and destination postings together"
  ,flagReq  ["close-desc"]   (\s opts -> Right $ setopt "close-desc" s opts) "DESC" "set closing transaction's description"
  ,flagReq  ["close-acct"]   (\s opts -> Right $ setopt "close-acct" s opts) "ACCT" "set closing transaction's destination account"
  ,flagReq  ["open-desc"]    (\s opts -> Right $ setopt "open-desc"  s opts) "DESC" "set opening transaction's description"
  ,flagReq  ["open-acct"]    (\s opts -> Right $ setopt "open-acct"  s opts) "ACCT" "set opening transaction's source account"
  ]
  [generalflagsgroup1]
  (hiddenflags
    ++  -- keep supporting old flag names for compatibility
    [flagNone ["closing"]   (setboolopt "close")                                   "old spelling of --close"
    ,flagNone ["opening"]   (setboolopt "open")                                    "old spelling of --open"
    ,flagReq  ["close-to"]  (\s opts -> Right $ setopt "close-acct" s opts) "ACCT" "old spelling of --close-acct"
    ,flagReq  ["open-from"] (\s opts -> Right $ setopt "open-acct"  s opts) "ACCT" "old spelling of --open-acct"
    ]
  )
  ([], Just $ argsFlag "[--close | --open | --migrate | --retain] [ACCTQUERY]")

-- Debugger, beware: close is incredibly devious; simple rules combine to make a horrid maze.
-- Tests are in hledger/test/close.test.
-- This code is also used by the close command.
close copts@CliOpts{rawopts_=rawopts, reportspec_=rspec0} j = do
  let
    -- currently only one of the six mode flags takes effect at a time (hledger close --close --open only does --open).
    (close_, open_, assert_, assign_, defclosedesc_, defopendesc_, defcloseacct_, defacctsq_) = if
      | boolopt "retain"  rawopts -> (True,  False, False, False, defretaindesc, undefined,   defretainacct, Type [Revenue, Expense])
      | boolopt "migrate" rawopts -> (True,  True,  False, False, defclosedesc,  defopendesc, defcloseacct,  Type [Asset, Liability, Equity])
      | boolopt "assign"  rawopts -> (False, False, False, True,  undefined,     defopendesc, defcloseacct,  Type [Asset, Liability, Equity])
      | boolopt "assert"  rawopts -> (False, False, True,  False, defclosedesc,  undefined,   defcloseacct,  Type [Asset, Liability, Equity])
      | boolopt "open"    rawopts -> (False, True,  False, False, undefined,     defopendesc, defcloseacct,  Type [Asset, Liability, Equity])
      | otherwise                 -> (True,  False, False, False, defclosedesc,  undefined,   defcloseacct,  Type [Asset, Liability, Equity]) -- close

    -- descriptions to use for the closing/opening transactions
    closedesc = T.pack $ fromMaybe defclosedesc_ $ maybestringopt "close-desc" rawopts
    opendesc  = T.pack $ fromMaybe defopendesc_  $ maybestringopt "open-desc"  rawopts

    -- equity/balancing accounts to use
    closeacct = T.pack $ fromMaybe defcloseacct_ $ maybestringopt "close-acct" rawopts
    openacct  = maybe closeacct T.pack $ maybestringopt "open-acct" rawopts

    ropts = (_rsReportOpts rspec0){balanceaccum_=Historical, accountlistmode_=ALFlat}
    rspec1 = setDefaultConversionOp NoConversionOp rspec0{_rsReportOpts=ropts}

    -- Dates of the closing and opening transactions.
    -- "The default closing date is yesterday, or the journal's end date, whichever is later.
    -- You can change this by specifying a [report end date](#report-start--end-date) with `-e`.
    -- The last day of the report period will be the closing date, eg `-e 2024` means "close on 2023-12-31".
    -- The opening date is always the day after the closing date."
    argsq = _rsQuery rspec1
    yesterday = addDays (-1) $ _rsDay rspec1
    yesterdayorjournalend = case journalLastDay False j of
      Just journalend -> max yesterday journalend
      Nothing         -> yesterday
    mreportlastday = addDays (-1) <$> queryEndDate False argsq
    closedate = fromMaybe yesterdayorjournalend  mreportlastday
    opendate = addDays 1 closedate

    -- should we show the amount(s) on the equity posting(s) ?
    explicit = boolopt "explicit" rawopts || copts ^. infer_costs

    -- the balances to close
    argsacctq = filterQuery (\q -> queryIsAcct q || queryIsType q) argsq
    q2 = if queryIsNull argsacctq then And [argsq, defacctsq_] else argsq
    rspec2 = rspec1{_rsQuery=q2}
    (acctbals',_) = balanceReport rspec2 j
    acctbals = map (\(a,_,_,b) -> (a, if show_costs_ ropts then b else mixedAmountStripPrices b)) acctbals'
    totalamt = maSum $ map snd acctbals

    -- since balance assertion amounts are required to be exact, the
    -- amounts in opening/closing transactions should be too (#941, #1137)
    precise = amountSetFullPrecision

    -- interleave equity postings next to the corresponding closing posting, or put them all at the end ?
    interleaved = boolopt "interleaved" rawopts

    -- the closing (balance-asserting or balance-zeroing) transaction
    closetxn = nulltransaction{tdate=closedate, tdescription=closedesc, tpostings=closeps}
    closeps
      -- XXX some duplication
      | assert_ =
        [ posting{
               paccount          = a
              ,pamount           = mixedAmount $ precise b{aquantity=0, aprice=Nothing}
              -- after each commodity's last posting, assert 0 balance (#1035)
              -- balance assertion amounts are unpriced (#824)
              ,pbalanceassertion =
                  if islast
                  then Just nullassertion{baamount=precise b}
                  else Nothing
              }
          | -- get the balances for each commodity and transaction price
            (a,mb) <- acctbals
          , let bs0 = amounts mb
            -- mark the last balance in each commodity with True
          , let bs2 = concat [reverse $ zip (reverse bs1) (True : repeat False)
                            | bs1 <- groupBy ((==) `on` acommodity) bs0]
          , (b, islast) <- bs2
        ]

      | otherwise =
        concat [
          posting{paccount          = a
                ,pamount           = mixedAmount . precise $ negate b
                -- after each commodity's last posting, assert 0 balance (#1035)
                -- balance assertion amounts are unpriced (#824)
                ,pbalanceassertion =
                    if islast
                    then Just nullassertion{baamount=precise b{aquantity=0, aprice=Nothing}}
                    else Nothing
                }

          -- maybe an interleaved posting transferring this balance to equity
          : [posting{paccount=closeacct, pamount=mixedAmount $ precise b} | interleaved]

          | -- get the balances for each commodity and transaction price
            (a,mb) <- acctbals
          , let bs0 = amounts mb
            -- mark the last balance in each commodity with True
          , let bs2 = concat [reverse $ zip (reverse bs1) (True : repeat False)
                            | bs1 <- groupBy ((==) `on` acommodity) bs0]
          , (b, islast) <- bs2
        ]

        -- or a final multicommodity posting transferring all balances to equity
        -- (print will show this as multiple single-commodity postings)
        ++ [posting{paccount=closeacct, pamount=if explicit then mixedAmountSetFullPrecision totalamt else missingmixedamt} | not interleaved]

    -- the opening (balance-assigning or balance-unzeroing) transaction
    opentxn = nulltransaction{tdate=opendate, tdescription=opendesc, tpostings=openps}
    openps
      | assign_ =
        [ posting{paccount         = a
                ,pamount           = missingmixedamt
                ,pbalanceassertion = Just nullassertion{baamount=b}
                    -- case mcommoditysum of
                    --   Just s  -> Just nullassertion{baamount=precise s}
                    --   Nothing -> Nothing
                }

          | (a,mb) <- acctbals
          , let bs0 = amounts mb
            -- mark the last balance in each commodity with the unpriced sum in that commodity (for a balance assertion)
          , let bs2 = concat [reverse $ zip (reverse bs1) (Just commoditysum : repeat Nothing)
                            | bs1 <- groupBy ((==) `on` acommodity) bs0
                            , let commoditysum = (sum bs1)]
          , (b, _mcommoditysum) <- bs2
        ]
        ++ [posting{paccount=openacct, pamount=if explicit then mixedAmountSetFullPrecision (maNegate totalamt) else missingmixedamt} | not interleaved]

      | otherwise =
        concat [
          posting{paccount          = a
                ,pamount           = mixedAmount $ precise b
                ,pbalanceassertion =
                    case mcommoditysum of
                      Just s  -> Just nullassertion{baamount=precise s{aprice=Nothing}}
                      Nothing -> Nothing
                }
          : [posting{paccount=openacct, pamount=mixedAmount . precise $ negate b} | interleaved]

          | (a,mb) <- acctbals
          , let bs0 = amounts mb
            -- mark the last balance in each commodity with the unpriced sum in that commodity (for a balance assertion)
          , let bs2 = concat [reverse $ zip (reverse bs1) (Just commoditysum : repeat Nothing)
                            | bs1 <- groupBy ((==) `on` acommodity) bs0
                            , let commoditysum = (sum bs1)]
          , (b, mcommoditysum) <- bs2
        ]
        ++ [posting{paccount=openacct, pamount=if explicit then mixedAmountSetFullPrecision (maNegate totalamt) else missingmixedamt} | not interleaved]

  -- print them
  when (close_ || assert_) . T.putStr $ showTransaction closetxn
  when (open_  || assign_) . T.putStr $ showTransaction opentxn
