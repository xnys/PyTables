########################################################################
#
#       License: BSD
#       Created: March 4, 2003
#       Author:  Francesc Alted - falted@openlc.org
#
#       $Source: /home/ivan/_/programari/pytables/svn/cvs/pytables/pytables/tables/utils.py,v $
#       $Id: utils.py,v 1.5 2003/11/25 11:26:26 falted Exp $
#
########################################################################

"""Utility functions

"""

import types

# Reserved prefixes for special attributes in Group and other classes
reservedprefixes = [
  '_c_',   # For class variables
  '_f_',   # For class public functions
  '_g_',   # For class private functions
  '_v_',   # For instance variables
]


def checkNameValidity(name):
    
    # Check if name starts with a reserved prefix
    for prefix in reservedprefixes:
        if (name.startswith(prefix)):
            raise NameError, \
"""Sorry, you cannot use a name like "%s" with the following reserved prefixes:\
  %s in this context""" % (name, reservedprefixes)
                
    # Check if new  node name have the appropriate set of characters
    # and is not one of the Python reserved word!
    # We use the next trick: exec the assignment 'name = 1' and
    # if a SyntaxError raises, catch it and re-raise a personalized error.
    
    testname = '_' + name + '_'
    try:
        exec(testname + ' = 1')  # Test for trailing and ending spaces
        exec(name + '= 1')  # Test for name validity
    except SyntaxError:
        raise NameError, \
"""\'%s\' is not a valid python identifier and cannot be used in this context.
  Check for special symbols ($, %%, @, ...), spaces or reserved words.""" % \
  (name)

if __name__=="__main__":
    import sys
    import getopt

    usage = \
"""usage: %s [-v] name
  -v means ...\n""" \
    % sys.argv[0]
    
    try:
        opts, pargs = getopt.getopt(sys.argv[1:], 'v')
    except:
        sys.stderr.write(usage)
        sys.exit(0)

    # if we pass too much parameters, abort
    if len(pargs) <> 1:
        sys.stderr.write(usage)
        sys.exit(0)
    name = sys.argv[1]

    # default options
    verbose = 0

    # Get the options
    for option in opts:
        if option[0] == '-v':
            verbose = 1

    # Catch the name to be validated
    name = pargs[0]
    
    checkNameValidity(name)

    print "Correct name: '%s'" % name

def calcBufferSize(rowsize, expectedrows, compress):
    """Calculate the buffer size and the HDF5 chunk size.

    The logic to do that is based purely in experiments playing
    with different buffer sizes, chunksize and compression
    flag. It is obvious that using big buffers optimize the I/O
    speed when dealing with tables. This might (should) be further
    optimized doing more experiments.

    """

    # A bigger buffer makes the writing faster and reading slower (!)
    #bufmultfactor = 1000 * 10
    # A smaller buffer also makes the tests to not take too much memory
    # We choose the smaller one
    # In addition, with the new iterator in the Row class, this seems to
    # be the best choice in terms of performance!
    bufmultfactor = int(1000 * 1.0)
    rowsizeinfile = rowsize
    expectedfsizeinKb = (expectedrows * rowsizeinfile) / 1024

    # Some code to compute appropiate values for chunksize & buffersize
    # chunksize:  The chunksize for the HDF5 library
    # buffersize: The Table internal buffer size
    #
    # Rational: HDF5 takes the data in bunches of chunksize length
    # to write the on disk. A BTree in memory is used to map structures
    # on disk. The more chunks that are allocated for a dataset the
    # larger the B-tree. Large B-trees take memory and causes file
    # storage overhead as well as more disk I/O and higher contention
    # for the meta data cache.
    # You have to balance between memory and I/O overhead (small B-trees)
    # and time to access to data (big B-trees).
    #
    # The tuning of the chunksize & buffersize parameters affects the
    # performance and the memory size consumed. This is based on
    # experiments on a Intel arquitecture and, as always, your mileage
    # may vary.
    if expectedfsizeinKb <= 100:
        # Values for files less than 100 KB of size
        buffersize = 5 * bufmultfactor
        chunksize = 1024
    elif (expectedfsizeinKb > 100 and
        expectedfsizeinKb <= 1000):
        # Values for files less than 1 MB of size
        buffersize = 20 * bufmultfactor
        chunksize = 2048
    elif (expectedfsizeinKb > 1000 and
          expectedfsizeinKb <= 20 * 1000):
        # Values for sizes between 1 MB and 20 MB
        buffersize = 40  * bufmultfactor
        chunksize = 4096
    elif (expectedfsizeinKb > 20 * 1000 and
          expectedfsizeinKb <= 200 * 1000):
        # Values for sizes between 20 MB and 200 MB
        buffersize = 50 * bufmultfactor
        chunksize = 8192
    else:  # Greater than 200 MB
        # These values gives an increment of memory of 50 MB for a table
        # size of 2.2 GB. I think this increment should be attributed to
        # the BTree which is created to save the table data.
        # If we increment this values more than that, the HDF5 takes
        # considerably more CPU. If you don't want to spend 50 MB
        # (or more, depending on the final table size) to
        # the BTree, and want to save files bigger than 2 GB,
        # try to increment this values, but be ready for a quite big
        # overhead needed to traverse the BTree.
        buffersize = 60 * bufmultfactor
        chunksize = 16384
    # Correction for compression.
    if compress:
        chunksize = 1024   # This seems optimal for compression

    # Max Tuples to fill the buffer
    maxTuples = buffersize // rowsize
    # Safeguard against row sizes being extremely large
    # I think this is not necessary because of the protection against
    # too large row sizes, but just in case.
    if maxTuples == 0:
        maxTuples = 1
    # A new correction for avoid too many calls to HDF5 I/O calls
    # But this does not bring advantages rather the contrary,
    # the memory comsumption grows, and performance is worse.
    #buffersize = 100    # For testing purposes
    #if expectedrows//maxTuples > 50:
    #    buffersize *= 4
    #    maxTuples = buffersize // rowsize
    return (maxTuples, chunksize)
        
def processRange(nrows, start=None, stop=None, step=None):

    assert (type(start) in
            [types.NoneType, types.IntType, types.LongType]), \
        "Non valid start parameter: %s" % start

    assert (type(stop) in
            [types.NoneType, types.IntType, types.LongType]), \
        "Non valid stop parameter: %s" % stop

    assert (type(step) in
            [types.NoneType, types.IntType, types.LongType]), \
        "Non valid step parameter: %s" % step

    if (not (start is None)) and ((stop is None) and (step is None)):
        step = 1
        if start < 0:
            start = nrows + start
        stop = start + 1
    else:
        if start is None:
            start = 0
        elif start < 0:
            start = nrows + start
        elif start > nrows:
            start = nrows

        if stop is None:
            stop = nrows
        elif stop <= 0 :
            stop = nrows + stop
        elif stop > nrows:
            stop = nrows

        if step is None:
            step = 1
        elif step <= 0:
            raise ValueError, \
                  "Zero or negative step values are not allowed!"
        
    # Protection against reading more than available records
#     if stop > nrows or start > nrows:
#         raise IndexError, \
# "Start (%s) or stop (%s) value is greater than number of rows (%s)." % \
# (start, stop, self.nrows)

    return (start, stop, step)
    
