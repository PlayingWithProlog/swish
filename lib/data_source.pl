/*  Part of SWISH

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2017, VU University Amsterdam
			 CWI Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(swish_data_source,
          [ data_source/2,              % :Id, +Source
            data_record/2,              % :Id, -Record
            record/2,                   % :Id, -Record
            data_signature/2,           % :Id, -Signature

            data_flush/1,               % +Hash
            'data assert'/1,            % +Term
            'data materialized'/3,	% +Hash, +Signature, +SourceID
            'data failed'/2		% +Hash, +Signature
          ]).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(settings)).

:- setting(max_memory, integer, 8000,
           "Max memory used for cached data store (Mb)").


/** <module> Cached data access

This module provides access to external data   by caching it as a Prolog
predicate. The data itself is kept in  a   global  data module, so it is
maintained over a SWISH Pengine invocation.
*/

:- meta_predicate
    data_source(:, +),
    data_record(:, -),
    record(:, -),
    data_signature(:, -).

:- multifile
    source/2.                           % +Term, -Goal


		 /*******************************
		 *          ADMIN DATA		*
		 *******************************/

:- dynamic
    data_source_db/3,                   % Hash, Goal, Lock
    data_signature_db/2,                % Hash, Signature
    data_materialized/5,                % Hash, Materialized, SourceID, CPU, Wall
    data_last_access/3.                 % Hash, Time, Updates

'data assert'(Term) :-
    assertz(Term).

'data materialized'(Hash, Signature, SourceID) :-
    statistics(cputime, CPU1),
    get_time(Now),
    nb_current('$data_source_materalize', stats(Time0, CPU0)),
    CPU  is CPU1 - CPU0,
    Wall is Now - Time0,
    assertz(data_signature_db(Hash, Signature)),
    assertz(data_materialized(Hash, Now, SourceID, CPU, Wall)).

'data failed'(_Hash, Signature) :-
    functor(Signature, Name, Arity),
    functor(Generic, Name, Arity),
    retractall(Generic).

%!  data_source(:Id, +Source) is det.
%
%   Make the CSV data in URL available   using  Id. Given this id, dicts
%   with a tag Id are expanded to goals   on  the CSV data. In addition,
%   record(Id, Record) gives a full data record   as a dict. Options are
%   as defined by csv//2.  In addition, these options are processed:
%
%     - encoding(+Encoding)
%       Set the encoding for processing the data.  Default is guessed
%       from the URL header or `utf8` if there is no clue.
%     - columns(+ColumnNames)
%       Names for the columns. If not provided, the first row is assumed
%       to hold the column names.

data_source(M:Id, Source) :-
    variant_sha1(Source, Hash),
    data_source_db(Hash, Source, _),
    !,
    (   clause(M:'$data'(Id, Hash), true)
    ->  true
    ;   assertz(M:'$data'(Id, Hash))
    ).
data_source(M:Id, Source) :-
    valid_source(Source),
    variant_sha1(Source, Hash),
    mutex_create(Lock),
    assertz(data_source_db(Hash, Source, Lock)),
    assertz(M:'$data'(Id, Hash)).

%!  record(:Id, -Record) is nondet.
%!  data_record(:Id, -Record) is nondet.
%
%   True when Record is  a  dict  representing   a  row  in  the dataset
%   identified by Id.
%
%   @deprecated  record/2  is   deprecated.   New    code   should   use
%   data_record/2.

record(Id, Record) :-
    data_record(Id, Record).

data_record(M:Id, Record) :-
    data_hash(M:Id, Hash),
    materialize(Hash),
    data_signature_db(Hash, Signature),
    data_record(Signature, Id, Record, Head),
    call(Head).

data_record(Signature, Tag, Record, Head) :-
    Signature =.. [Name|Keys],
    pairs_keys_values(Pairs, Keys, Values),
    dict_pairs(Record, Tag, Pairs),
    Head =.. [Name|Values].

%!  data_signature(:Id, -Signature)
%
%   True when Signature is the signature of the data source Id.  The
%   signature is a compound term Id(ColName, ...)

data_signature(M:Id, Signature) :-
    data_hash(M:Id, Hash),
    materialize(Hash),
    data_signature_db(Hash, Signature0),
    Signature0 =.. [_|ColNames],
    Signature  =.. [Id|ColNames].

data_hash(M:Id, Hash) :-
    clause(M:'$data'(Id, Hash), true),
    !.
data_hash(_:Id, _) :-
    existence_error(dataset, Id).

%!  swish:goal_expansion(+Dict, -DataGoal)
%
%   Translate a Dict where the tag is   the  identifier of a data source
%   and the keys are columns pf this  source   into  a goal on the data.
%   Note that the data itself  is   represented  as  a Prolog predicate,
%   representing each row as a fact and each column as an argument.

:- multifile
    swish:goal_expansion/2.

swish:goal_expansion(Dict, swish_data_source:Head) :-
    is_dict(Dict, Id),
    prolog_load_context(module, M),
    clause(M:'$data'(Id, Hash), true),
    materialize(Hash),
    data_signature_db(Hash, Signature),
    data_record(Signature, Id, Record, Head),
    Dict :< Record.


		 /*******************************
		 *       DATA MANAGEMENT	*
		 *******************************/

valid_source(Source) :-
    must_be(nonvar, Source),
    source(Source, _Goal),
    !.
valid_source(Source) :-
    existence_error(data_source, Source).

%!  materialize(+Hash)
%
%   Materialise the data identified by   Hash.  The materialization goal
%   should
%
%     - Call 'data assert'/1 using a term Hash(Arg, ...) for each term
%       to add to the database.
%     - Call 'data materialized'(Hash, Signature, SourceVersion) on
%       completion, where `Signature` is a term Hash(ArgName, ...) and
%       `SourceVersion` indicates the version info provided by the
%       source.  Use `-` if this information is not available.
%     - OR call `data failed`(+Hash, +Signature) if materialization
%       fails after some data has been asserted.

materialize(Hash) :-
    must_be(atom, Hash),
    data_materialized(Hash, _When, _From, _CPU, _Wall),
    !,
    update_last_access(Hash).
materialize(Hash) :-
    data_source_db(Hash, Source, Lock),
    update_last_access(Hash),
    gc_data,
    with_mutex(Lock, materialize_sync(Hash, Source)).

materialize_sync(Hash, _Source) :-
    data_materialized(Hash, _When, _From, _CPU, _Wall),
    !.
materialize_sync(Hash, Source) :-
    source(Source, Goal),
    get_time(Time0),
    statistics(cputime, CPU0),
    setup_call_cleanup(
        b_setval('$data_source_materalize', stats(Time0, CPU0)),
        call(Goal, Hash),
        nb_delete('$data_source_materalize')),
    data_signature_db(Hash, Head),
    functor(Head, Name, Arity),
    public(Name/Arity).


		 /*******************************
		 *              GC		*
		 *******************************/

%!  update_last_access(+Hash) is det.
%
%   Update the last known access time. The   value  is rounded down to 1
%   minute to reduce database updates.

update_last_access(Hash) :-
    get_time(Now),
    Rounded is floor(Now/60)*60,
    (   data_last_access(Hash, Rounded, _)
    ->  true
    ;   clause(data_last_access(Hash, _, C0), true, Old)
    ->  C is C0+1,
        asserta(data_last_access(Hash, Rounded, C)),
        erase(Old)
    ;   asserta(data_last_access(Hash, Rounded, 1))
    ).

gc_stats(Hash, _{ hash:Hash,
                  materialized:When, cpu:CPU, wall:Wall,
                  bytes:Size,
                  last_accessed_ago:Ago,
                  access_frequency:AccessCount
                }) :-
    data_materialized(Hash, When, _From, CPU, Wall),
    data_signature_db(Hash, Signature),
    data_last_access(Hash, Last, AccessCount),
    get_time(Now),
    Ago is floor(Now/60)*60-Last,
    predicate_property(Signature, number_of_clauses(Count)),
    functor(Signature, _, Arity),
    Size is (88+(16*Arity))*Count.


%!  gc_data is det.
%!  gc_data(+MaxSize) is det.
%
%   Remove the last unused data set until   memory  of this module drops
%   below  MaxSize.  The   predicate   gc_data/0    is   called   before
%   materializing a data source.

gc_data :-
    setting(max_memory, MB),
    Bytes is MB*1024*1024,
    gc_data(Bytes),
    set_module(program_space(Bytes)).

gc_data(MaxSize) :-
    module_property(swish_data_source, program_size(Size)),
    Size < MaxSize,
    !.
gc_data(MaxSize) :-
    findall(Stat, gc_stats(_, Stat), Stats),
    sort(last_accessed_ago, >=, Stats, ByTime),
    member(Stat, ByTime),
       data_flush(ByTime.hash),
       module_property(swish_data_source, program_size(Size)),
       Size < MaxSize,
    !.
gc_data(_).


%!  data_flush(+Hash)
%
%   Drop the data associated with hash

data_flush(Hash) :-
    data_signature_db(Hash, Signature),
    data_record(Signature, _Id, _Record, Head),
    retractall(Head),
    retractall(data_signature_db(Hash, Head)),
    retractall(data_materialized(Hash, _When1, _From, _CPU, _Wall)),
    retractall(data_last_access(Hash, _When2, _Count)).


		 /*******************************
		 *            SANDBOX		*
		 *******************************/

:- multifile
    sandbox:safe_meta/2.

sandbox:safe_meta(swish_data_source:data_source(Id,_), [])     :- safe_id(Id).
sandbox:safe_meta(swish_data_source:data_record(Id, _), [])    :- safe_id(Id).
sandbox:safe_meta(swish_data_source:data_signature(Id, _), []) :- safe_id(Id).

safe_id(_:_) :- !, fail.
safe_id(_).