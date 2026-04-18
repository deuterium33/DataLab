# -*- coding: utf-8 -*-

"""
Empty plugin example
====================

This is an empty example of a DataLab plugin.

It adds a new menu entry in "Plugins" menu, with a sub-menu "Empty plugin (example)".
This sub-menu contains one action, "Do nothing".
"""

import numpy as np
import matplotlib.pyplot as plt
plt.rcParams["axes.formatter.useoffset"] = False
plt.rcParams["axes.formatter.use_mathtext"] = True
plt.rcParams["figure.autolayout"] = True
import seaborn as sns
sns.set_context("poster", font_scale=0.7)

import datalab.plugins
import sigima.proc.image as sipi
import sigima.proc.signal as sips
import guidata.dataset as gds

from mpl_toolkits.axes_grid1 import make_axes_locatable

class MPparams(gds.DataSet, title="Multiplot options"):
    """Multiplot options parameters"""
    _plot_g = gds.BeginGroup("Plotting options")
    _prop = gds.ValueProp(False)
    merge = gds.BoolItem("Same graph?", default=False).set_prop("display", active=gds.NotProp(_prop)) 
    clear = gds.BoolItem("Clear graphs first?", default=True)
    combine = gds.BoolItem("Combine plots?",default=False).set_prop("display", store=_prop)
    method = gds.ChoiceItem("Method", (("standard_deviation","Average + Standard Deviation"),("min_max","Average + Min/Max"))).set_prop("display", active=_prop)
    alpha = gds.FloatItem("Opacity error band", default=0.5, min=0, max=1, slider=True).set_prop("display", active=_prop) 
    _plot_g_e = gds.EndGroup("Plotting options")

class toMPL(datalab.plugins.PluginBase):
    """Pluging to plot in Matplotlib"""
    PLUGIN_INFO = datalab.plugins.PluginInfo(
        name="Plot in Matplotlib",
        version="1.0.0",
        description="This plugin plot the selected objects with Matplotlib/Seaborn",
    )
    
    def plotMPLimages(self) -> None:
        """Plot images in Matplotlib"""
        items = self.proxy.get_sel_object_uuids()
        for item in items:
            img = self.proxy.get_object(item)
            fig, ax = plt.subplots()
            im = ax.imshow(img.data,extent=[img.xmin,img.xmax,img.ymin,img.ymax])
            ax.set_xlabel(f'{img.xlabel} ({img.xunit})') if img.xunit else plt.xlabel(f'{img.xlabel}')
            ax.set_ylabel(f'{img.ylabel} ({img.yunit})') if img.yunit else plt.ylabel(f'{img.ylabel}')
            ax.set_title(img.title)
            #divider = make_axes_locatable(ax)
            #cax = divider.append_axes("right", size="5%", pad=0.1)
            cbar=fig.colorbar(im,aspect=30)
            #cbar = fig.colorbar(im, cax=cax)
            #cbar.outline.set_linewidth(1)
            #cbar.ax.tick_params(width=1)
            cbar.set_label(f'{img.zlabel} ({img.zunit})') if img.zunit else cbar.set_label(f'{img.zlabel}')
            fig.tight_layout()
        return plt.show()
        
    def plotMPLsignals(self) -> None:
        """Plot signals in Matplotlib"""
        items = self.proxy.get_sel_object_uuids()
        combine = False
        merge = False
        clear = False
        if len(items)>1:
            param = MPparams("Multiplot options")
            if not param.edit(self.main):
                return
            combine = param.combine
            merge = param.merge
            clear = param.clear
        if clear:
            plt.close('all')
        if not combine or len(items)<2:
            for item in items:
                sig = self.proxy.get_object(item)
                if not merge:
                    plt.figure()
                if sig.dx is not None or sig.dy is not None:
                    plt.errorbar(sig.x,sig.y,xerr=sig.dx,yerr=sig.dy,label=sig.title)
                else:
                    plt.plot(sig.x,sig.y,label=sig.title)
                plt.xlabel(f'{sig.xlabel} ({sig.xunit})') if sig.xunit else plt.xlabel(f'{sig.xlabel}')
                plt.ylabel(f'{sig.ylabel} ({sig.yunit})') if sig.yunit else plt.ylabel(f'{sig.ylabel}')
                plt.title(sig.title)
                if merge:
                    plt.title('')
                    plt.legend()
                plt.tight_layout()
        else:
            self.proxy.select_objects(items)
            self.proxy.calc("average")
            avg = self.proxy.get_object()
            plt.figure()
            if param.method=="standard_deviation":
                self.proxy.select_objects(items)
                self.proxy.calc("standard_deviation")
                std = self.proxy.get_object()
                plt.plot(avg.x,avg.y)
                plt.fill_between(avg.x,avg.y-std.y,avg.y+std.y,alpha=param.alpha)
            if param.method=="min_max":
                self.proxy.select_objects(items)
                self.proxy.calc("minimum")
                minimum = self.proxy.get_object()
                self.proxy.select_objects(items)
                self.proxy.calc("maximum")
                maximum = self.proxy.get_object()
                plt.plot(avg.x,avg.y)
                plt.fill_between(avg.x,minimum.y,maximum.y,alpha=param.alpha)
            sig = self.proxy.get_object(items[0])
            plt.xlabel(f'{sig.xlabel} ({sig.xunit})') if sig.xunit else plt.xlabel(f'{sig.xlabel}')
            plt.ylabel(f'{sig.ylabel} ({sig.yunit})') if sig.yunit else plt.ylabel(f'{sig.ylabel}')
            if not combine:
                plt.legend()
            plt.tight_layout()
        return plt.show()
    
    def create_actions(self) -> None:
        """Create actions"""
        acthi = self.imagepanel.acthandler
        with acthi.new_menu(self.PLUGIN_INFO.name):
            # Note: in the following call, `select_condition` is by default `None`,
            # so the action is enabled only if at least one image is selected.
            acthi.new_action("Plot in Matplotlib", triggered=self.plotMPLimages)
        acths = self.signalpanel.acthandler
        with acths.new_menu(self.PLUGIN_INFO.name):
            # Note: in the following call, `select_condition` is by default `None`,
            # so the action is enabled only if at least one signal is selected.
            acths.new_action("Plot in Matplotlib", triggered=self.plotMPLsignals)
