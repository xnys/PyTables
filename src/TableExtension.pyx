#  Ei!, emacs, this is -*-Python-*- mode
########################################################################
#
#       License: BSD
#       Created: June 17, 2005
#       Author:  Francesc Altet - faltet@carabos.com
#
#       $Id$
#
########################################################################

"""Here is where Table and Row extension types live.

Classes (type extensions):

    Table
    Row

Functions:



Misc variables:

    __version__
"""

import numpy

import tables.hdf5Extension
from tables.exceptions import HDF5ExtError
from tables.conditions import call_on_recarr
from tables.utilsExtension import createNestedType, \
     getNestedType, convertTime64, getTypeEnum, enumFromHDF5

# numpy functions & objects
from definitions cimport import_array, ndarray, \
     malloc, free, strcpy, strcmp, strdup, \
     PyString_AsString, Py_BEGIN_ALLOW_THREADS, Py_END_ALLOW_THREADS, \
     PyArray_GETITEM, PyArray_SETITEM, \
     H5F_ACC_RDONLY, H5P_DEFAULT, H5D_CHUNKED, H5T_DIR_DEFAULT, \
     H5F_SCOPE_LOCAL, H5F_SCOPE_GLOBAL, \
     size_t, hid_t, herr_t, hsize_t, htri_t, H5D_layout_t, \
     H5Gunlink, H5Fflush, H5Dopen, H5Dclose, H5Dread, H5Dget_type,\
     H5Dget_space, H5Dget_create_plist, H5Pget_layout, H5Pclose, \
     H5Sget_simple_extent_ndims, H5Sget_simple_extent_dims, H5Sclose, \
     H5Tget_size, H5Tcreate, H5Tcopy, H5Tclose, H5Tget_sign, \
     H5ATTRset_attribute_string, H5ATTRset_attribute, \
     get_len_of_range


# Include HDF5 types
include "convtypetables.pxi"

from lrucacheExtension cimport NumCache

__version__ = "$Revision$"



#-----------------------------------------------------------------

# Optimized HDF5 API for PyTables
cdef extern from "H5TB-opt.h":

  herr_t H5TBOmake_table( char *table_title, hid_t loc_id, char *dset_name,
                          char *version, char *class_,
                          hid_t mem_type_id, hsize_t nrecords,
                          hsize_t chunk_size, int compress,
                          char *complib, int shuffle, int fletcher32,
                          void *data )

  herr_t H5TBOread_records( hid_t dataset_id, hid_t mem_type_id,
                            hsize_t start, hsize_t nrecords, void *data )

  herr_t H5TBOread_elements( hid_t dataset_id, hid_t mem_type_id,
                             hsize_t nrecords, void *coords, void *data )

  herr_t H5TBOappend_records( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t nrecords, hsize_t nrecords_orig,
                              void *data )

  herr_t H5TBOwrite_records ( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t start, hsize_t nrecords,
                              hsize_t step, void *data )

  herr_t H5TBOwrite_elements( hid_t dataset_id, hid_t mem_type_id,
                              hsize_t nrecords, void *coords, void *data )

  herr_t H5TBOdelete_records( hid_t   dataset_id, hid_t   mem_type_id,
                              hsize_t ntotal_records, size_t  src_size,
                              hsize_t start, hsize_t nrecords,
                              hsize_t maxtuples )


#----------------------------------------------------------------------------

# Initialization code

# The numpy API requires this function to be called before
# using any numpy facilities in an extension module.
import_array()

#-------------------------------------------------------------



# XXX This should inherit from `tables.hdf5Extension.Leaf`,
# XXX but I don't know the Pyrex machinery to make it work.
# XXX ivb(2005-07-21)

cdef class Table:  # XXX extends Leaf
  # instance variables
  cdef void     *rbuf, *wbuf
  cdef hsize_t  totalrecords
  cdef char     *name  # XXX from Node
  cdef hid_t    parent_id  # XXX from Node
  cdef hid_t    dataset_id, type_id, disk_type_id


  def _g_new(self, where, name, init):
    self.name = strdup(name)  # XXX from Node._g_new()
    # The parent group id for this object
    self.parent_id = where._v_objectID  # XXX from Node._g_new()
    if init:
      self.dataset_id = -1
      self.type_id = -1
      self.disk_type_id = -1


  def _g_delete(self):  # XXX Should inherit from Node
    cdef int ret

    # Delete this node
    ret = H5Gunlink(self.parent_id, self.name)
    if ret < 0:
      raise HDF5ExtError("problems deleting the node ``%s``" % self.name)
    return ret


  def _createTable(self, char *title, char *complib, char *obversion):
    cdef int     offset
    cdef int     ret
    cdef long    buflen
    cdef hid_t   oid
    cdef void    *data
    cdef hsize_t nrecords
    cdef char    *class_
    cdef object  fieldname, name
    cdef ndarray recarr

    # Compute the complete compound datatype based on the table description
    self.type_id = createNestedType(self.description, self.byteorder)
    # The on-disk type should be the same than in-memory
    self.disk_type_id = H5Tcopy(self.type_id)

    # test if there is data to be saved initially
    if self._v_recarray is not None:
      self.totalrecords = self.nrows
      recarr = self._v_recarray
      data = recarr.data
    else:
      self.totalrecords = 0
      data = NULL

    class_ = PyString_AsString(self._c_classId)
    self.dataset_id = H5TBOmake_table(title, self.parent_id, self.name,
                                      obversion, class_, self.type_id,
                                      self.nrows, self._v_chunksize,
                                      self.filters.complevel, complib,
                                      self.filters.shuffle,
                                      self.filters.fletcher32,
                                      data)
    if self.dataset_id < 0:
      raise HDF5ExtError("Problems creating the table")

    # Set the conforming table attributes
    # Attach the CLASS attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "CLASS", class_)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("CLASS", self.name))
    # Attach the VERSION attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "VERSION", obversion)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("VERSION", self.name))
    # Attach the TITLE attribute
    ret = H5ATTRset_attribute_string(self.dataset_id, "TITLE", title)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("TITLE", self.name))
    # Attach the NROWS attribute
    nrecords = self.nrows
    ret = H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                              0, NULL, <char *>&nrecords )
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         ("NROWS", self.name))

    # Attach the FIELD_N_NAME attributes
    # We write only the first level names
    for i, name in enumerate(self.description._v_names):
      fieldname = "FIELD_%s_NAME" % i
      ret = H5ATTRset_attribute_string(self.dataset_id, fieldname, name)
    if ret < 0:
      raise HDF5ExtError("Can't set attribute '%s' in table:\n %s." %
                         (fieldname, self.name))

    # If created in PyTables, the table is always chunked
    self._chunked = 1  # Accessible from python

    # Finally, return the object identifier.
    return self.dataset_id


  def _getInfo(self):
    "Get info from a table on disk."
    cdef hid_t   space_id
    cdef size_t  type_size
    cdef hsize_t dims[1]  # enough for unidimensional tables
    cdef hid_t   plist
    cdef H5D_layout_t layout

    # Open the dataset
    self.dataset_id = H5Dopen(self.parent_id, self.name)
    # Get the datatype on disk
    self.disk_type_id = H5Dget_type(self.dataset_id)
    # Get the number of rows
    space_id = H5Dget_space(self.dataset_id)
    H5Sget_simple_extent_dims(space_id, dims, NULL)
    self.totalrecords = dims[0]
    # Make totalrecords visible in python space
    self.nrows = self.totalrecords
    # Free resources
    H5Sclose(space_id)

    # Get the layout of the datatype
    plist = H5Dget_create_plist(self.dataset_id)
    layout = H5Pget_layout(plist)
    H5Pclose(plist)
    if layout == H5D_CHUNKED:
      self._chunked = 1
    else:
      self._chunked = 0

    # Get the type size
    type_size = H5Tget_size(self.disk_type_id)
    # Create the native data in-memory
    self.type_id = H5Tcreate(H5T_COMPOUND, type_size)
    # Fill-up the (nested) native type and description
    desc = getNestedType(self.disk_type_id, self.type_id, self)
    if desc == {}:
      raise HDF5ExtError("Problems getting desciption for table %s", self.name)

    # Return the object ID and the description
    return (self.dataset_id, desc)


  def _loadEnum(self, hid_t fieldTypeId):
    """_loadEnum(colname) -> (Enum, naType)
    Load enumerated type associated with `colname` column.

    This method loads the HDF5 enumerated type associated with
    `colname`.  It returns an `Enum` instance built from that, and the
    NumPy type used to encode it.
    """

    cdef hid_t enumId

    enumId = getTypeEnum(fieldTypeId)

    # Get the Enum and NumPy types and close the HDF5 type.
    try:
      return enumFromHDF5(enumId)
    finally:
      # (Yes, the ``finally`` clause *is* executed.)
      if H5Tclose(enumId) < 0:
        raise HDF5ExtError("failed to close HDF5 enumerated type")


  def _convertTypes(self, object recarr, hsize_t nrecords, int sense):
    """Converts columns in 'recarr' between NumPy and HDF5 formats.

    NumPy to HDF5 conversion is performed when 'sense' is 0.
    Otherwise, HDF5 to NumPy conversion is performed.  The conversion
    is done in place, i.e. 'recarr' is modified.  """

    # This should be generalised to support other type conversions.
    for t64cname in self._time64colnames:
      column = recarr
      for field in t64cname.split('/'):
        column = column[field]
      convertTime64(column, nrecords, sense)


  def _open_append(self, ndarray recarr):
    self._v_recarray = <object>recarr
    # Get the pointer to the buffer data area
    self.wbuf = recarr.data


  def _append_records(self, int nrecords):
    cdef int ret

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(self._v_recarray, nrecords, 0)

    # release GIL (allow other threads to use the Python interpreter)
    Py_BEGIN_ALLOW_THREADS
    # Append the records:
    ret = H5TBOappend_records(self.dataset_id, self.type_id,
                              nrecords, self.totalrecords, self.wbuf)
    # acquire GIL (disallow other threads from using the Python interpreter)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems appending the records.")

    self.totalrecords = self.totalrecords + nrecords


  def _close_append(self):

    # Update the NROWS attribute
    if (H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                            0, NULL, <char *>&self.totalrecords) < 0):
      raise HDF5ExtError("Problems setting the NROWS attribute.")

    # Set the caches to dirty (in fact, and for the append case,
    # it should be only the caches based on limits, but anyway)
    self._dirtycache = True


  def _update_records(self, hsize_t start, hsize_t stop,
                      hsize_t step, ndarray recarr):
    cdef herr_t ret
    cdef void *rbuf
    cdef hsize_t nrecords, nrows

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Compute the number of records to update
    nrecords = len(recarr)
    nrows = get_len_of_range(start, stop, step)
    if nrecords > nrows:
      nrecords = nrows

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(recarr, nrecords, 0)
    # Update the records:
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOwrite_records(self.dataset_id, self.type_id,
                             start, nrecords, step, rbuf )
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems updating the records.")

    # Set the caches to dirty
    self._dirtycache = True


  def _update_elements(self, hsize_t nrecords, ndarray elements,
                       ndarray recarr):
    cdef herr_t ret
    cdef void *rbuf, *coords

    # Get the chunk of the coords that correspond to a buffer
    coords = elements.data

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Convert some NumPy types to HDF5 before storing.
    self._convertTypes(recarr, nrecords, 0)
    # Update the records:
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOwrite_elements(self.dataset_id, self.type_id,
                              nrecords, coords, rbuf)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems updating the records.")

    # Set the caches to dirty
    self._dirtycache = True


  def _read_records(self, hsize_t start, hsize_t nrecords, ndarray recarr):
    cdef long buflen
    cdef void *rbuf
    cdef int ret

    # Correct the number of records to read, if needed
    if (start + nrecords) > self.totalrecords:
      nrecords = self.totalrecords - start

    # Get the pointer to the buffer data area
    rbuf = recarr.data

    # Read the records from disk
    Py_BEGIN_ALLOW_THREADS
    ret = H5TBOread_records(self.dataset_id, self.type_id, start,
                            nrecords, rbuf)
    Py_END_ALLOW_THREADS
    if ret < 0:
      raise HDF5ExtError("Problems reading records.")

    # Convert some HDF5 types to NumPy after reading.
    self._convertTypes(recarr, nrecords, 1)

    return nrecords


  def _read_elements(self, recarr, elements):
    return self._read_elements_(recarr, elements)


  cdef _read_elements_(self, ndarray recarr, ndarray elements):
    cdef long buflen, rowsize, nrecord, nrecords
    cdef void *rbuf, *rbuf2
    cdef hsize_t *coords, coord
    cdef int ret
    cdef long nslot
    cdef NumCache sparsecache


    # Get the chunk of the coords that correspond to a buffer
    nrecords = elements.size
    # The size of the one single row
    rowsize = self.rowsize
    # Get the pointer to the buffer data area
    rbuf = recarr.data
    # Get the pointer to the buffer coords area
    rbuf2 = elements.data
    coords = <hsize_t *>rbuf2

    # Clean-up the cache if needed
    if self._dirtycache:
      self._restorecache()

    sparsecache = <NumCache>self._sparsecache
    for nrecord from 0 <= nrecord < nrecords:
      coord = coords[nrecord]
      # Look at the cache for this coord
      nslot = sparsecache.getslot(coord)
      if nslot >= 0:
        sparsecache.getitem2(nslot, rbuf, nrecord)
      else:
        rbuf2 = <void *>(<char *>rbuf + nrecord*rowsize)
        # The coord is not in cache. Read it and put it in the LRU cache.
        ret = H5TBOread_records(self.dataset_id, self.type_id,
                                coord, 1, rbuf2)
        if ret < 0:
          raise HDF5ExtError("Problems reading record: %s" % (coord))
        sparsecache.setitem(coord, rbuf, nrecord)

    # Convert some HDF5 types to NumPy after reading.
    self._convertTypes(recarr, nrecords, 1)

    return nrecords


  def _remove_row(self, hsize_t nrow, hsize_t nrecords):
    cdef size_t rowsize

    # Protection against deleting too many rows
    if (nrow + nrecords > self.totalrecords):
      nrecords = self.totalrecords - nrow

    rowsize = self.rowsize
    # Using self.disk_type_id should be faster (i.e. less conversions)
    if (H5TBOdelete_records(self.dataset_id, self.disk_type_id,
                            self.totalrecords, rowsize, nrow, nrecords,
                            self._v_maxTuples) < 0):
      raise HDF5ExtError("Problems deleting records.")
      #print "Problems deleting records."
      # Return no removed records
      return 0
    self.totalrecords = self.totalrecords - nrecords
    # Attach the NROWS attribute
    H5ATTRset_attribute(self.dataset_id, "NROWS", H5T_STD_I64,
                        0, NULL, <char *>&self.totalrecords)
    # Set the caches to dirty
    self._dirtycache = True
    # Return the number of records removed
    return nrecords


  def  _get_type_id(self):
    "Accessor to type_id"
    return self.type_id


  def _g_flush(self):
    # Flush the dataset (in fact, the entire buffers in file!)
    if self.dataset_id >= 0:
        H5Fflush(self.dataset_id, H5F_SCOPE_GLOBAL)


  def _g_close(self):
    # Close dataset in HDF5 space
    # Release resources
    if self.type_id >= 0:
      H5Tclose(self.type_id)
    if self.disk_type_id >= 0:
      H5Tclose(self.disk_type_id)
    if self.dataset_id >= 0:
      H5Dclose(self.dataset_id)


  def __dealloc__(self):
    #print "Destroying object Table in Extension"
    free(<void *>self.name)  # XXX from Node



cdef class Row:
  """Row Class

  This class hosts accessors to a recarray row. The fields on a
  recarray can be accessed both as items (__getitem__/__setitem__),
  i.e. following the "map" protocol.

  """

  cdef long    _row, _unsaved_nrows, _mod_nrows
  cdef hsize_t start, stop, step, nextelement, _nrow
  cdef hsize_t nrowsinbuf, nrows, nrowsread, stopindex
  cdef int     bufcounter, counter, startb, stopb,  _all
  cdef int     exist_enum_cols
  cdef int     _riterator, _stride
  cdef int     whereCond, indexed, indexChunk
  cdef int     ro_filemode, chunked
  cdef int     _bufferinfo_done
  cdef Table   table
  cdef object  dtype
  cdef object  rbufRA, wbufRA
  cdef object  _wfields, _rfields
  cdef object  indexValid, coords, bufcoords, index, indices
  cdef object  condfunc, condargs
  cdef object  mod_elements, colenums

  #def __new__(self, Table table):
    # The MIPSPro C compiler on a SGI does not like to have an assignation
    # of a type Table to a type object. For now, as we do not have to call
    # C methods in Tables, I'll declare table as object.
    # F. Altet 2004-02-11
  def __new__(self, table):
    cdef int nfields, i
    # Location-dependent information.
    self.table = table
    self._unsaved_nrows = table._unsaved_nrows
    self._mod_nrows = 0
    self._row = self._unsaved_nrows
    self._nrow = 0   # Useful in mod_append read iterators
    self._riterator = 0
    self._bufferinfo_done = 0
    self.rbufRA = None
    self.wbufRA = None
    # Some variables from table will be cached here
    if table._v_file.mode == 'r':
      self.ro_filemode = 1
    else:
      self.ro_filemode = 0
    self.chunked = table._chunked
    self.colenums = table._colenums
    self.exist_enum_cols = len(self.colenums)
    self.nrowsinbuf = table._v_maxTuples
    self.dtype = table._v_dtype


  def __call__(self, start=0, stop=0, step=1, coords=None, ncoords=0):
    """ return the row for this record object and update counters"""

    self._initLoop(start, stop, step, coords, ncoords)
    return iter(self)


  def __iter__(self):
    "Iterator that traverses all the data in the Table"

    return self


  cdef _newBuffer(self, write):
    "Create the recarray for I/O buffering"

    if write:
      # Get the write buffer in table (it is unique, remember!)
      buff = self.wbufRA = self.table._v_wbuffer
      #self._wfields = buff._fields
      # Build the _rfields dictionary for faster access to columns
      self._wfields = {}
      for name in self.dtype.names:
        self._wfields[name] = buff[name]
      # Initialize an array for keeping the modified elements
      # (just in case Row.update() would be used)
      self.mod_elements = numpy.empty(shape=self.nrowsinbuf,
                                      dtype=numpy.int64)
    else:
      #buff = self.rbufRA = self.table._newBuffer(init=0)
      buff = self.rbufRA = numpy.empty(shape=self.nrowsinbuf,
                                       dtype=self.dtype)
      # Build the _rfields dictionary for faster access to columns
      # This is quite fast, as it only takes around 5 us per column
      # in my laptop (Pentium 4 @ 2 GHz).
      # F. Altet 2006-08-18
      self._rfields = {}
      for name in self.dtype.names:
        self._rfields[name] = buff[name]

    # Get the stride of this buffer
    self._stride = buff.strides[0]
    self.nrows = self.table.nrows  # This value may change


  cdef _initLoop(self, hsize_t start, hsize_t stop, hsize_t step,
                 object coords, int ncoords):
    "Initialization for the __iter__ iterator"

    self._riterator = 1   # We are inside a read iterator
    self._newBuffer(False)   # Create a buffer for reading
    self.start = start
    self.stop = stop
    self.step = step
    self.coords = coords
    self.startb = 0
    self.nrowsread = start
    self._nrow = start - self.step
    self.whereCond = 0
    self.indexed = 0

    table = self.table
    self.nrows = table.nrows   # Update the row counter

    if table._whereCondition:
      self.whereCond = 1
      self.condfunc, self.condargs = table._whereCondition
      table._whereCondition = None
    if table._whereIndex:
      self.indexed = 1
      self.index = table.cols._g_col(table._whereIndex).index
      self.indices = self.index.indices
      self.nrowsread = 0
      self.nextelement = 0
      table._whereIndex = None

    if self.coords is not None:
      self.stopindex = coords.size
      self.nrowsread = 0
      self.nextelement = 0
    elif self.indexed:
      self.stopindex = ncoords


  def __next__(self):
    "next() method for __iter__() that is called on each iteration"
    if self.indexed or self.coords is not None:
      return self.__next__indexed()
    elif self.whereCond:
      return self.__next__inKernel()
    else:
      return self.__next__general()


  cdef __next__indexed(self):
    """The version of next() for indexed columns or with user coordinates"""
    cdef int recout
    cdef long long stop
    cdef long long nextelement

    while self.nextelement < self.stopindex:
      if self.nextelement >= self.nrowsread:
        # Correction for avoiding reading past self.stopindex
        if self.nrowsread+self.nrowsinbuf > self.stopindex:
          stop = self.stopindex-self.nrowsread
        else:
          stop = self.nrowsinbuf
        if self.coords is not None:
          self.bufcoords = self.coords[self.nrowsread:self.nrowsread+stop]
          nrowsread = self.bufcoords.size
        else:
          # Optmized version of getCoords in Pyrex
          self.bufcoords = self.indices._getCoords(self.index,
                                                   self.nrowsread, stop)
          nrowsread = self.bufcoords.size
          tmp = self.bufcoords
          # If a step was specified, select the strided elements first
          if tmp.size > 0 and self.step > 1:
            tmp2=(tmp-self.start) % self.step
            tmp = tmp[tmp2.__eq__(0)]
          # Now, select those indices in the range start, stop:
          if tmp.size > 0 and self.start > 0:
            # Pyrex can't use the tmp>=number notation when tmp is a numpy
            # object. Why?
            # XYX Xequejar aco per a numpy...
            tmp = tmp[tmp.__ge__(self.start)]
          if tmp.size > 0 and self.stop < self.nrows:
            tmp = tmp[tmp.__lt__(self.stop)]
          self.bufcoords = tmp
        self._row = -1
        if self.bufcoords.size > 0:
          recout = self.table._read_elements_(self.rbufRA, self.bufcoords)
          if self.whereCond:
            # Evaluate the condition on this table fragment.
            self.indexValid = call_on_recarr(
              self.condfunc, self.condargs, self._rfields )
          else:
            # No residual condition, all selected rows are valid.
            self.indexValid = numpy.ones(recout, numpy.bool8)
        else:
          recout = 0
        self.nrowsread = self.nrowsread + nrowsread
        # Correction for elements that are eliminated by its
        # [start:stop:step] range
        self.nextelement = self.nextelement + nrowsread - recout
        if recout == 0:
          # no items where read, skipping
          continue
      self._row = self._row + 1
      self._nrow = self.bufcoords[self._row]
      self.nextelement = self.nextelement + 1
      # Return this row if it fullfills the residual condition
      if self.indexValid[self._row]:
        return self
    else:
      # Re-initialize the possible cuts in columns
      self.indexed = 0
      self.coords = None
      # All the elements have been read for this mode
      nextelement = self.nrows
      if nextelement >= self.nrows:
        self.finish_riterator()
      else:
        # Continue the iteration with the __next__inKernel() method
        self.start = nextelement
        self.startb = 0
        self.nrowsread = self.start
        self._nrow = self.start - self.step
        return self.__next__inKernel()


  cdef __next__inKernel(self):
    """The version of next() in case of in-kernel conditions"""
    cdef int recout, correct
    cdef object numexpr_locals, colvar, col

    self.nextelement = self._nrow + self.step
    while self.nextelement < self.stop:
      if self.nextelement >= self.nrowsread:
        # Skip until there is interesting information
        while self.nextelement >= self.nrowsread + self.nrowsinbuf:
          self.nrowsread = self.nrowsread + self.nrowsinbuf
        # Compute the end for this iteration
        self.stopb = self.stop - self.nrowsread
        if self.stopb > self.nrowsinbuf:
          self.stopb = self.nrowsinbuf
        self._row = self.startb - self.step
        # Read a chunk
        recout = self.table._read_records(self.nextelement, self.nrowsinbuf,
                                          self.rbufRA)
        self.nrowsread = self.nrowsread + recout
        self.indexChunk = -self.step

        # Evaluate the condition on this table fragment.
        self.indexValid = call_on_recarr(
          self.condfunc, self.condargs, self._rfields )

        # Is still there any interesting information in this buffer?
        if not numpy.sometrue(self.indexValid):
          # No, so take the next one
          if self.step >= self.nrowsinbuf:
            self.nextelement = self.nextelement + self.step
          else:
            self.nextelement = self.nextelement + self.nrowsinbuf
            # Correction for step size > 1
            if self.step > 1:
              correct = (self.nextelement - self.start) % self.step
              self.nextelement = self.nextelement + self.step - correct
          continue

      self._row = self._row + self.step
      self._nrow = self.nextelement
      if self._row + self.step >= self.stopb:
        # Compute the start row for the next buffer
        self.startb = 0

      self.nextelement = self._nrow + self.step
      # Return only if this value is interesting
      self.indexChunk = self.indexChunk + self.step
      if self.indexValid[self.indexChunk]:
        return self
    else:
      self.finish_riterator()


  # This is the most general __next__ version, simple, but effective
  cdef __next__general(self):
    """The version of next() for the general cases"""
    cdef int recout

    self.nextelement = self._nrow + self.step
    while self.nextelement < self.stop:
      if self.nextelement >= self.nrowsread:
        # Skip until there is interesting information
        while self.nextelement >= self.nrowsread + self.nrowsinbuf:
          self.nrowsread = self.nrowsread + self.nrowsinbuf
        # Compute the end for this iteration
        self.stopb = self.stop - self.nrowsread
        if self.stopb > self.nrowsinbuf:
          self.stopb = self.nrowsinbuf
        self._row = self.startb - self.step
        # Read a chunk
        recout = self.table._read_records(self.nrowsread, self.nrowsinbuf,
                                          self.rbufRA)
        self.nrowsread = self.nrowsread + recout

      self._row = self._row + self.step
      self._nrow = self.nextelement
      if self._row + self.step >= self.stopb:
        # Compute the start row for the next buffer
        self.startb = (self._row + self.step) % self.nrowsinbuf

      self.nextelement = self._nrow + self.step
      # Return this value
      return self
    else:
      self.finish_riterator()


  cdef finish_riterator(self):
    """Clean-up things after iterator has been done"""

    self._riterator = 0        # out of iterator
    if self._mod_nrows > 0:    # Check if there is some modified row
      self._flushModRows()       # Flush any possible modified row
    raise StopIteration        # end of iteration


  def _fillCol(self, result, start, stop, step, field):
    "Read a field from a table on disk and put the result in result"
    cdef hsize_t startr, stopr, i, j, istartb, istopb
    cdef hsize_t istart, istop, istep, inrowsinbuf, inextelement, inrowsread
    cdef object fields

    # We can't reuse existing buffers in this context
    self._initLoop(start, stop, step, None, 0)
    istart, istop, istep = (self.start, self.stop, self.step)
    inrowsinbuf, inextelement, inrowsread = (self.nrowsinbuf, istart, istart)
    istartb, startr = (self.startb, 0)
    i = istart
    while i < istop:
      if (inextelement >= inrowsread + inrowsinbuf):
        inrowsread = inrowsread + inrowsinbuf
        i = i + inrowsinbuf
        continue
      # Compute the end for this iteration
      istopb = istop - inrowsread
      if istopb > inrowsinbuf:
        istopb = inrowsinbuf
      stopr = startr + ((istopb - istartb - 1) / istep) + 1
      # Read a chunk
      inrowsread = inrowsread + self.table._read_records(i, inrowsinbuf,
                                                         self.rbufRA)
      # Assign the correct part to result
      fields = self.rbufRA
      if field:
        for nestedfield in field.split('/'):
          fields = fields[nestedfield]
      result[startr:stopr] = fields[istartb:istopb:istep]

      # Compute some indexes for the next iteration
      startr = stopr
      j = istartb + ((istopb - istartb - 1) / istep) * istep
      istartb = (j+istep) % inrowsinbuf
      inextelement = inextelement + istep
      i = i + inrowsinbuf
    self._riterator = 0  # out of iterator
    return


  # The nrow() method has been converted into a property, which is handier
  property nrow:
    "Makes current row visible from Python space."
    def __get__(self):
      return self._nrow


  def append(self):
    """Append self object to the output buffer."""

    if self.ro_filemode:
      raise IOError("Attempt to write over a file opened in read-only mode")

    if not self.chunked:
      raise HDF5ExtError("You cannot append rows to a non-chunked table.")

    if self._riterator:
      raise NotImplementedError("You cannot append rows when in middle of a table iterator. If what you want is updating records, use Row.update() instead.")

    self._unsaved_nrows = self._unsaved_nrows + 1
    self.table._unsaved_nrows = self._unsaved_nrows
    # When the buffer is full, flush it
    if self._unsaved_nrows == self.nrowsinbuf:
      table = self.table
      # Save the records on disk
      table._saveBufferedRows()
      # Reset the buffer unsaved counter
      self._unsaved_nrows = 0
      # self.table._unsaved_nrows *has* to be reset in table._saveBufferedRows
      # so that flush works well.


  def update(self):
    """Update current row copying it from the input buffer."""

    if self.ro_filemode:
      raise IOError("Attempt to write over a file opened in read-only mode")

    if self.wbufRA is None:
      # Get the array pointers for write buffers
      self._newBuffer(True)

    if not self._riterator:
      raise NotImplementedError("You are only allowed to update rows through the Row.update() method if you are in the middle of a table iterator.")

    # Add this row to the list of elements to be modified
    self.mod_elements[self._mod_nrows] = self._nrow
    # Copy the current buffer row in input to the output buffer
    self.wbufRA[self._mod_nrows] = self.rbufRA[self._row]
    # Increase the modified buffer count by one
    self._mod_nrows = self._mod_nrows + 1
    # When the buffer is full, flush it
    if self._mod_nrows == self.nrowsinbuf:
      self._flushModRows()


  def _flushModRows(self):
    """Flush any possible modified row using Row.update()"""

    table = self.table
    # Save the records on disk
    table._update_elements(self._mod_nrows, self.mod_elements, self.wbufRA)
    # Reset the counter of modified rows to 0
    self._mod_nrows = 0
    # Redo the indexes if needed. This could be optimized if we would
    # be able to track the modified columns.
    table._reIndex(table.colnames)


  # This method is twice as faster than __getattr__ because there is
  # not a lookup in the local dictionary
  def __getitem__(self, fieldName):
    cdef long offset
    cdef ndarray field
    cdef object field2

    # Optimization follows for the case that the field dimension is
    # == 1, i.e. columns elements are scalars, and the column is not
    # of String type. This code accelerates the access to column
    # elements a 20%

    try:
      field2 = self._rfields
      for nestedfield in fieldName.split('/'):
        field2 = field2[nestedfield]
      field = field2
    except KeyError:
      raise KeyError("no such column: %s" % (fieldName,))

    # Get the column index. This is very fast!
    if field.nd == 1:
      #return field[self._row]
      # Optimization for numpy
      offset = self._row * self._stride
      return PyArray_GETITEM(field, field.data + offset)
    else:  # Case when dimensions > 1
      # Make a copy of the (multi) dimensional array
      # so that the user does not have to do that!
      return field[self._row].copy()


  # This is slightly faster (around 3%) than __setattr__
  def __setitem__(self, fieldName, object value):
    cdef ndarray field
    cdef object field2
    cdef long offset
    cdef int ret

    if self.ro_filemode:
      raise IOError("attempt to write over a file opened in read-only mode")

    if self.wbufRA is None:
      # Get the array pointers for write buffers
      self._newBuffer(True)

    # Check validity of enumerated value.
    if self.exist_enum_cols:
      if fieldName in self.colenums:
        enum = self.colenums[fieldName]
        for cenval in numpy.asarray(value).flat:
          enum(cenval)  # raises ``ValueError`` on invalid values

    try:
      if self._riterator:
        # We are in the middle of an iterator for reading. So the
        # user most probably wants to update this row.
        field2 = self._rfields
        offset = self._row
      else:
        field2 = self._wfields
        offset = self._unsaved_nrows
      for nestedfield in fieldName.split('/'):
        field2 = field2[nestedfield]
      field = field2
    except KeyError:
      raise KeyError("no such column: %s" % (fieldName,))

    try:
      # field[offset] = value
      # Optimization for scalar values. This can optimize the writes
      # between a 10% and 100%, depending on the number of columns modified
      # F. Altet 2005-10-25
      if field.nd == 1:
        offset = offset * self._stride
        ret = PyArray_SETITEM(field, field.data + offset, value)
        if ret < 0:
          raise TypeError
      ##### End of optimization for scalar values
      else:
        field[offset] = value
    except TypeError:
      raise TypeError("invalid type (%s) for column ``%s``" % (type(value),
                                                               fieldName))
    if not self._riterator:
      # Before write and read buffer got separated, we were able to write:
      # row['var1'] = '%04d' % (self.expectedrows - i)
      # row['var7'] = row['var1'][-1]
      # during table fillings. This is to allow this to continue happening.
      # F. Altet 2005-04-25
      self._rfields = self._wfields
      self._row = self._unsaved_nrows


  def __str__(self):
    """ represent the record as an string """

    # We need to do a cast for recognizing negative row numbers!
    if <signed long long>self._nrow < 0:
      return "Warning: Row iterator has not been initialized for table:\n  %s\n %s" % \
             (self.table, \
    "You will normally want to use this object in iterator contexts.")

    outlist = []
    # Special case where Row has not been initialized yet
    if self.rbufRA is None and self.wbufRA is None:
      return "Warning: Row iterator has not been initialized for table:\n  %s\n %s" % \
             (self.table, \
"You will normally want to use to use this object in iterator or writing contexts.")
    if self.rbufRA is not None:
      buf = self.rbufRA;  fields = self._rfields
    else:
      buf = self.wbufRA;  fields = self._wfields
    for name in buf.dtype.names:
      outlist.append(`fields[name][self._row]`)
    return "(" + ", ".join(outlist) + ")"


  def __repr__(self):
    """ represent the record as an string """
    return str(self)


  def __dealloc__(self):
    #print "Deleting Row object"
    pass

