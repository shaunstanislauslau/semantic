{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables, TypeOperators #-}
module Parser where

import qualified CMark
import Data.Record
import qualified Data.Syntax as Syntax
import Data.Syntax.Assignment
import Data.Functor.Foldable hiding (fold, Nil)
import qualified Data.Text as T
import Data.Union
import Info hiding (Empty, Go)
import Language
import Language.Markdown
import qualified Language.Markdown.Syntax as Markdown
import qualified Language.Python.Syntax as Python
import qualified Language.Ruby.Syntax as Ruby
import Prologue hiding (Location)
import Source
import Syntax hiding (Go)
import System.Console.ANSI
import Term
import qualified Text.Parser.TreeSitter as TS
import Text.Parser.TreeSitter.Language (Symbol)
import Text.Parser.TreeSitter.C
import Text.Parser.TreeSitter.Go
import Text.Parser.TreeSitter.Python
import Text.Parser.TreeSitter.Ruby
import Text.Parser.TreeSitter.TypeScript
import Text.Show
import TreeSitter

-- | A parser from 'Source' onto some term type.
data Parser term where
  -- | A parser producing 'AST' using a 'TS.Language'.
  ASTParser :: (Bounded grammar, Enum grammar) => Ptr TS.Language -> Parser (Cofree [] (Record (Maybe grammar ': Location)))
  -- | A parser producing an à la carte term given an 'AST'-producing parser and an 'Assignment' onto 'Term's in some syntax type. Assignment errors will result in a top-level 'Syntax.Error' node.
  AssignmentParser :: (Enum grammar, Eq grammar, Show grammar, Symbol grammar, Syntax.Error (Error grammar) :< fs, Foldable (Union fs), Functor (Union fs), Recursive ast, Foldable (Base ast))
                   => Parser ast                                                   -- ^ A parser producing AST.
                   -> (forall x. Base ast x -> Record (Maybe grammar ': Location)) -- ^ A function extracting the symbol and location.
                   -> Assignment ast grammar (Term (Union fs) (Record Location))   -- ^ An assignment from AST onto 'Term's.
                   -> Parser (Term (Union fs) (Record Location))                   -- ^ A parser producing 'Term's.
  -- | A tree-sitter parser.
  TreeSitterParser :: Language -> Ptr TS.Language -> Parser (SyntaxTerm Text DefaultFields)
  -- | A parser for 'Markdown' using cmark.
  MarkdownParser :: Parser (Cofree [] (Record (CMark.NodeType ': Location)))
  -- | A parser which will parse any input 'Source' into a top-level 'Term' whose children are leaves consisting of the 'Source's lines.
  LineByLineParser :: Parser (SyntaxTerm Text DefaultFields)

-- | Return a 'Language'-specific 'Parser', if one exists, falling back to the 'LineByLineParser'.
parserForLanguage :: Maybe Language -> Parser (SyntaxTerm Text DefaultFields)
parserForLanguage Nothing = LineByLineParser
parserForLanguage (Just language) = case language of
  C -> TreeSitterParser C tree_sitter_c
  Go -> TreeSitterParser Go tree_sitter_go
  JavaScript -> TreeSitterParser TypeScript tree_sitter_typescript
  Ruby -> TreeSitterParser Ruby tree_sitter_ruby
  TypeScript -> TreeSitterParser TypeScript tree_sitter_typescript
  _ -> LineByLineParser

rubyParser :: Parser Ruby.Term
rubyParser = AssignmentParser (ASTParser tree_sitter_ruby) headF Ruby.assignment

pythonParser :: Parser Python.Term
pythonParser = AssignmentParser (ASTParser tree_sitter_python) headF Python.assignment

markdownParser :: Parser Markdown.Term
markdownParser = AssignmentParser MarkdownParser (\ ((nodeType :. location) :< _) -> Just (toGrammar nodeType) :. location) Markdown.assignment

runParser :: Parser term -> Source -> IO term
runParser parser = case parser of
  ASTParser language -> parseToAST language
  AssignmentParser parser by assignment -> \ source -> do
    ast <- runParser parser source
    let Result err term = assignBy by assignment source ast
    traverse_ (putStrLn . showError source) (toList err)
    case term of
      Just term -> do
        let errors = termErrors term `asTypeOf` toList err
        traverse_ (putStrLn . showError source) errors
        unless (Prologue.null errors) $
          putStrLn (withSGRCode [SetConsoleIntensity BoldIntensity, SetColor Foreground Vivid Red] (shows (Prologue.length errors) . showChar ' ' . showString (if Prologue.length errors == 1 then "error" else "errors")) $ "")
        pure term
      Nothing -> pure (errorTerm source err)
  TreeSitterParser language tslanguage -> treeSitterParser language tslanguage
  MarkdownParser -> pure . cmarkParser
  LineByLineParser -> lineByLineParser
  where showSGRCode = showString . setSGRCode
        withSGRCode code s = showSGRCode code . s . showSGRCode []

errorTerm :: Syntax.Error (Error grammar) :< fs => Source -> Maybe (Error grammar) -> Term (Union fs) (Record Location)
errorTerm source err = cofree ((totalRange source :. totalSpan source :. Nil) :< inj (Syntax.Error (fromMaybe (Error (SourcePos 0 0) (UnexpectedEndOfInput [])) err)))

termErrors :: (Syntax.Error (Error grammar) :< fs, Functor (Union fs), Foldable (Union fs)) => Term (Union fs) a -> [Error grammar]
termErrors = cata $ \ (_ :< s) -> case s of
  _ | Just (Syntax.Error err) <- prj s -> [err]
  _ -> fold s

-- | A fallback parser that treats a file simply as rows of strings.
lineByLineParser :: Source -> IO (SyntaxTerm Text DefaultFields)
lineByLineParser source = pure . cofree . root $ case foldl' annotateLeaves ([], 0) lines of
  (leaves, _) -> cofree <$> leaves
  where
    lines = actualLines source
    root children = (sourceRange :. Program :. rangeToSourceSpan source sourceRange :. Nil) :< Indexed children
    sourceRange = Source.totalRange source
    leaf byteIndex line = (Range byteIndex (byteIndex + T.length line) :. Program :. rangeToSourceSpan source (Range byteIndex (byteIndex + T.length line)) :. Nil) :< Leaf line
    annotateLeaves (accum, byteIndex) line =
      (accum <> [ leaf byteIndex (Source.toText line) ] , byteIndex + Source.length line)
