# -*- coding: utf-8 -*-
"""
Created on Wed Apr 15 13:53:13 2026

@author: mathi
"""

import numpy as np
import yt
from sigima.io.base import FormatInfo
from sigima.io.image.base import MultipleImagesFormatBase

# ==============================================================================
# FLASH file format
# ==============================================================================

class FLASHImageFormat(MultipleImagesFormatBase):
    """Object representing FLASH output file type"""

    FORMAT_INFO = FormatInfo(
        name="FLASH",
        extensions="*.h5",
        readable=True,
        writeable=False,
        requires=["yt"]
    )
    
    @staticmethod
    def read_data(filename: str) -> np.ndarray:
        """Read data and return it

        Args:
            filename (str): path to FLASH file

        Returns:
            np.ndarray: image data
        """
        ds = yt.load(filename)
        level = ds.max_level
        ind=np.argwhere(ds.domain_dimensions==1).ravel()[0]
        right_edge = ds.domain_right_edge.in_cgs().to_ndarray()
        left_edge = ds.domain_left_edge.in_cgs().to_ndarray()
        domain_dimensions=(ds.domain_dimensions*(2)**(level)).astype('int')
        domain_dimensions[ind]=1
        ngridx, ngridy, ngridz = domain_dimensions
        uniform_data = ds.arbitrary_grid(left_edge,right_edge,dims=domain_dimensions)
        images = []
        print('List of fields availables, add it to the plugin if needed: {}'.format(np.array(ds.field_list)[:,1]))
        for idx,field in enumerate(['dens','nele','tele','tion','magy','targ']):
            print('{0:02d}: {1}'.format(idx,field))
            if field=='nele': # convert to e-/cm^3
                img = 6.022e23*np.squeeze(uniform_data['dens'].in_cgs().to_ndarray())*np.squeeze(uniform_data['ye'].in_cgs().to_ndarray())
            elif (field=='tele' or field=='tion'): # convert to eV
                img = 8.617e-5*np.squeeze(uniform_data[field].in_cgs().to_ndarray())
            elif field=='magy': # convert to Tesla
                img = 3.555*1e-4*np.squeeze(uniform_data[field].in_cgs().to_ndarray())
            else:
                img = np.squeeze(uniform_data[field].in_cgs().to_ndarray())
            images.append(img.T)
        print('CGS units, except: temperature in eV, magnetic field in T')
        return np.array(images)