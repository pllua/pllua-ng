
pllua_ng
========

Embeds Lua into PostgreSQL as a procedural language module.

This code is still under development and probably contains bugs and
missing functionality. However, all the basic stuff should work.

WARNING: interfaces are not stable and are subject to change.

Currently it should build against pg 9.6 and pg10 (and 11devel). It
is known that this module will never work on pg versions before 9.5
(we rely critically on memory context callbacks, which were introduced
in that version).

Only Lua 5.3 is fully supported at this time, though it also is
believed to mostly work if built against LuaJIT with the COMPAT52
option.

Bugs can be reported by opening issues on github.


CHANGES
-------

Some names and locations have been changed.

The old pllua.init table is gone. Instead we support three init
strings (superuser-only): pllua_ng.on_init, pllua_ng.on_trusted_init,
pllua_ng.on_untrusted_init.

Note that the on_init string can be run in the postmaster process, by
including pllua_ng in shared_preload_libraries. Accordingly, on_init
cannot do any database access, and the only functions available from
this module are the server.log/debug/error/etc. ones. (print() will
do nothing useful.)

NB.: because on_init is run before the sandbox environment is set up
for trusted interpreters, it can't use trusted.require() or
trusted.allow() and modules that it loads will not be visible inside
the sandbox. To preload modules for use by trusted interpreters, you
need to use on_init to require the module initially, and then use
on_trusted_init to run trusted.allow or trusted.require to make it
available.

SPI functionality is now in global table spi and has different calling
conventions:

      spi.execute("query text", arg, arg, ...)
      spi.execute_count("query text", maxrows, arg, arg, ...)
      spi.prepare("query text", {argtypes}, [{options}])
        - returns a statement object:
          s:execute(arg, arg, ...)  - returns a result table
          s:execute_count(maxrows, arg, arg, ...)  - returns a result table
          s:rows(arg, arg, ...) - returns iterator
      spi.rows("query text", args...)
        - returns iterator

Execution now returns a table with no number keys (#t == 0) in the
event of no matching rows, whereas the old version returned nil. The
result is also currently a plain table, not an object.

spi.prepare takes an options table with these possible values:

      scroll = true or false
      no_scroll = true
      fast_start = true
      custom_plan = true
      generic_plan = true
      fetch_count = integer

Note that "scroll" and "no_scroll" are independent options to the
planner, but we treat { scroll = false } as if it were { no_scroll = true }
because not doing so would be too confusing. The fetch_count value is
used only by the :rows iterator, to determine how much prefetch to use;
the default is 50. (Smaller values might be desirable for fetching very
large rows, or a value of 1 disables prefetch entirely.)

Cursors work:

      spi.findcursor("name")   - find already-open portal by name
      spi.newcursor(["name"])  - find existing cursor or create new one
      s:getcursor(args)   - get cursor from statement (can't specify name)
      c:open(stmt,args)   - open a cursor
      c:open(query,args)  - open a cursor
      c:isopen()          - is it open
      c:name()
      c:fetch([n, [dir]])  - fetch n rows in dir (default: forward 1)
      c:move([n, [dir]])

There can only be one cursor object for a given open portal - doing a
findcursor on an existing cursor will always return the same object.
(But note that this matching is by portal, not name - if a cursor was
closed and reopened with the same name, findcursor will return a
different object for the new cursor.) If a cursor is closed by
external code (or transaction end), then the :isopen() state will be
automatically updated (this happens when the portal is actually
dropped). Cursor options are set on the statement object.

:save on a statement is now a no-op - all statements seen by lua code
have been passed through SPI_keepplan and are managed by Lua garbage
collection. (It was never safe to do otherwise.)

(SPI interface is particularly subject to change - in particular to
something more compatible with client-side database APIs)

print() is still a global function to print an informational message,
but other error levels such as debug, notice are installed as
server.debug(), server.warning() etc.  server.elog('error', ...)
is equivalent to server.error(...) and so on.

server.error() and friends can take optional args:

      server.error('message')
      server.error('sqlstate', 'message')
      server.error('sqlstate', 'message', 'detail')
      server.error('sqlstate', 'message', 'detail', 'hint')
      server.error({ sqlstate = ?,
                     message = ?,
                     detail = ?,
                     hint = ?,
                     table = ?,
                     column = ?, ...})

(I'd like to deprecate the server.* namespace but I don't have a good
alternative place to put these functions. Suggestions welcome.)

Sqlstates can be given either as 5-character strings or as the string
names used in plpgsql: server.error('invalid_argument', 'message')

Subtransactions are implemented via pcall() and xpcall(), which now
run the called function in a subtransaction. In the case of xpcall,
the subtransaction is ended *before* running the error function, which
therefore runs in the outer subtransaction. This does mean that while
Lua errors in the error function cause recursion and are eventually
caught by the xpcall, if an error function causes a PG error then the
xpcall will eventually rethrow that to its own caller. (This is
subject to change if I decide it was a bad idea.)

e.g.

      local ok,err = pcall(function() --[[ do stuff in subxact ]] end)
      if not ok then print("subxact failed with error",err) end

Currently there's also lpcall and lxpcall functions which do NOT
create subtransactions, but which will catch only Lua errors and not
PG errors (which are immediately rethrown). It's not clear yet how
useful this is; it saves the (possibly significant) subxact overhead,
but it can be quite unpredictable whether any given error will
manifest as a Lua error or a PG error.

The readonly-global-table and setshared() hacks are omitted. As the
trusted language now creates an entirely separate lua_State for each
calling userid, anything the user does in the global environment can
only affect themselves.

Type handling is all different. The global fromstring() is replaced by
the pgtype package/function:

      pgtype(d)
        -- if d is a pg datum value, returns an object representing its
           type

      pgtype(d,n)
        -- if d is a datum, as above; if not, returns the object
           describing the type of argument N of the function, or the
           return type of the function if N==0

      pgtype['typename']
      pgtype.typename
      pgtype(nil, 'typename')
        -- parse 'typename' as an SQL type and return the object for it

      pgtype.array.typename
      pgtype.array['typename']
        -- return the type for "typename[]" if it exists

The object representing a type can then be called as a constructor for
datum objects of that type:

      pgtype['mytablename'](col1,col2,col3)
      pgtype['mytablename']({ col1 = val1, col2 = val2, col3 = val3})
      pgtype.numeric(1234)
      pgtype.date('2017-12-01')
      pgtype.array.integer(1,2,3,4)
      pgtype.array.integer({1,2,3,4}, 4)        -- dimension mandatory
      pgtype.array.integer({{1,2},{3,4}},2,2)   -- dimensions mandatory
      pgtype.numrange(1,2)        -- range type constructor
      pgtype.numrange(1,2,'[]')   -- range type constructor

or the :fromstring method can be used:

      pgtype.date:fromstring('string')

In turn, datum objects of composite type can be indexed by column
number or name:

      row.foo  -- value of column "foo"
      row[3]   -- note this is attnum=3, which might not be the third
                  column if columns have been dropped

Arrays can be indexed normally as a[1] or a[3][6] etc. By default
array indexes in PG start at 1, but values starting at other indexes
can be constructed. One-dimensional arrays (but not higher dimensions)
can be extended by adding elements with indexes outside the current
bounds; ranges of unassigned elements between assigned ones contain
NULL.

tostring() works on any datum and returns its string representation.

pairs() works on a composite datum (and actually returns the attnum as a
third result):

      for colname,value,attnum in pairs(row) do ...

The result is always in column order.

ipairs() should NOT be used on a composite datum since it will stop at
a null value or dropped column.

Arrays, composite types, and jsonb values support a mapping operation
controlled by a configuration table:

      rowval{ mapfunc = function(colname,value,attno,row) ... end,
              nullvalue = (any value),
              noresult = (boolean)
            }
      arrayval{ mapfunc = function(elem,array,i,j,k...) ... end,
                nullvalue = (any value),
                noresult = (boolean)
              }
      jsonbval{ mapfunc = function(key,val,...) ... return key,val end,
                nullvalue = (any value),
		noresult = (boolean),
		keep_numeric = (boolean)
              }

The result in all cases is returned as a Lua table, not a datum,
unless the "noresult" option was given as true, in which case no
result at all is returned.

The mapfunc for arrays is passed as many indexes as the original array
dimension.

The mapfunc for jsonb values is passed the path leading up to the
current key (not including the key) as separate additional parameters.
The key is an integer if the current container is an array, a string
if the container is an object, and nil if this is a single top-level
scalar value (which I believe is not strictly allowed in the json
spec, but pg allows it). The key/val returned by the mapfunc are used
to store the result, but do not affect the path values passed to any
other mapfunc call. If noresult is not specified, then the mapfunc is
also called for completed containers (in which case val will be a
table). If keep_numeric is not true, then numeric values are converted
to Lua numbers, otherwise they remain as Datum values of numeric type
(for which see below).

Substitution of null values happens BEFORE the mapping function is
called; if that's not what you want, then do the substitution yourself
before returning the result. (If the mapping function itself returns a
Lua nil, then the entry will be omitted from the result.)

As a convenience shorthand, these work:

      d(nvl)   -> d{nullvalue = nvl}
      d(func)  -> d{mapfunc = func}
      d()      -> d{}

Range types support the following pseudo-columns (immutable):

      r.lower
      r.upper
      r.lower_inc
      r.upper_inc
      r.lower_inf
      r.upper_inf
      r.isempty

Function arguments are converted to simple Lua values in the case of:

 + integers, floats  -- passed as Lua numbers

 + text, varchar, char, json (not jsonb), xml, cstring, name -- all passed
   as strings (with the padding preserved in the case of char(n))

 + enums  -- passed as the text label

 + bytea  -- passed as a string without any escaping or conversion

 + boolean  -- passed as boolean
 
 + nulls of any type  -- passed as nil

 + domains over any of the above are treated as the base types

Other values are kept as datum objects.

The trusted language is implemented differently - rather than removing
functions and packages, the trusted language evaluates all
user-supplied code (everything but the init strings) in a separate
environment table which contains only whitelisted content. A mini
version of the package library is installed in the sandbox
environment, allowing package.preload and package.searchers to work
(the user can install their own function into package.searchers to
load modules from database queries if they so wish).

pllua_ng.on_trusted_init is run in trusted interpreters in the global
env (not the sandbox env). It can do:

      trusted.allow('module' [,'newname'])
        -- requires 'module', then sets up the sandbox so that lua code
           can do  require 'newname'  and get access to the module
      trusted.require('module' [,'newname'])
        -- as above, but also does sandbox.newname = module
      trusted.remove('newname')
        -- undoes either of the above (probably not very useful, but you
           could do  trusted.remove('os')  or whatever)

The trusted environment's version of "load" overrides the text/binary
mode field (loading binary functions is unsafe) and overrides the
environment to be the trusted sandbox if the caller didn't provide one
itself (but the caller can still give an explicit environment of nil).

A set-returning function isn't considered to end until it either
returns or throws an error; yielding with no results is considered the
same as yielding with explicit nils. (Old version killed the thread in
that scenario.) A set-returning function that returns on the first
call with no result is treated as returning 0 rows, but if the first
call returns values, those are treated as the (only) result row.

Trigger functions no longer have a global "trigger" object, but rather
are compiled with the following definition:

      function(trigger,old,new,...) --[[ body here ]] end

"trigger" is now a userdata, not a table, but can be indexed as
before.  Trigger functions may assign a row to trigger.row, or modify
fields of trigger.row or trigger.new, or may return a row or table; if
they do none of these and return nothing, they're treated as returning
trigger.row unchanged. Note that returning nil or assigning row=nil to
suppress the triggered operation is in general a bad idea; if you need
to prevent an action, then throw an error instead.

An interface to pg's "numeric" type (decimal arithmetic) is provided.
Datums of numeric type can be used with Lua arithmetic operators, with
the other argument being converted to numeric if necessary. Supported
functions are available as method calls on a numeric datum or in the
package 'pllua.numeric' (which can be require'd normally):

 *  abs ceil equal exp floor isnan sign sqrt
 *  tointeger (returns nil if not representable as a Lua integer)
 *  tonumber  (returns a Lua number, not exact)
 *  log       (with optional base, defaults to natural log)
 *  trunc round  (with optional number of digits)

Values can be constructed with pgtype.numeric(blah) or, if you
require'd the pllua.numeric package, with the .new function.

NOTE: PG semantics, not Lua semantics, are used for the // and %
operators on numerics (pg uses truncate-to-zero and sign-of-dividend
rules, vs. Lua's truncate-to-minus-infinity and sign-of-divisor rules).
Also beware that == does not work to compare a numeric datum against
another number (this is a limitation of Lua), so use the :equal method
for such cases. (Other comparisons work, though note that PG semantics
are used for NaN.)

Polymorphic and variadic functions are fully supported, including
VARIADIC "any". VARIADIC of non-"any" type is passed as an array as
usual.

Interpreters are shut down on backend exit, meaning that finalizers
will be run for all objects at this time (including user-defined ones).
Currently, SPI functionality is disabled during exit.

AUTHOR
------

Andrew Gierth, aka RhodiumToad

The author acknowledges the work of Luis Carvalho and other contributors
to the original pllua project (of which this is a ground-up redesign).

License: MIT license
