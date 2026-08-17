(:name "nelisp-pkg"
 :version "0.1"
 ;; No cross-package dependencies: cl-lib and subr-x are host libraries,
 ;; which the graph classifies as unresolved-and-assumed-host rather than
 ;; as edges.  This file is here first because a package system whose own
 ;; metadata is missing has already lost the argument.
 :requires ())
