--

\set VERBOSITY terse

--

create function pg_temp.tmp1(n text) returns text
  language plluau immutable strict
  as $$ return (require "pllua.paths")[n]() $$;

-- some of the dirs might not actually exist, so we test
-- only the important ones.
select s.isdir
  from unnest(array['bin','lib','libdir','pkglib','share'])
         with ordinality as u(n,ord),
       pg_temp.tmp1(u.n) f(path),
       pg_stat_file(f.path) s
 order by u.ord;

-- test that bin/postgres is found (most other dirs don't
-- have filenames we can predict)
select s.isdir from pg_stat_file(pg_temp.tmp1('bin') || '/postgres') s;

--end