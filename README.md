JPData
======

Boilerplate for mapping from a JSON web service to Core Data models. Caching  
is built-in, with customisable timeouts.

Requirements:
-------------

* SBJson

Notes:
------

* Core Data models should use a trailing underscore where the associated JSON
  key is a reserved keyword, e.g. "id" can be named "id_" in the model.

* TODO: better docs!

